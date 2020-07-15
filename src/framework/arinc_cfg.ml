(** ARINC Control-flow graph implementation. *)

module GU = Goblintutil
module CF = Cilfacade
open Cil
open Deriving.Cil
include Arinc_node

type edgeAct =
  | Computation of int
  (** Computation that takes a certain WCET *)
  | ResumeTask of int
  (** Resume another task *)
  | SuspendTask of int
  (** Suspend another task *)
  | TimedWait of int
  | SetEvent of int
  | WaitEvent of int
  | ResetEvent of int
  | WaitSemaphore of int
  | SignalSemaphore of int
  | PeriodicWait
  | WaitingForPeriod
  | WaitingForEndWait
  | NOP
  [@@deriving to_yojson]

type edge = int * edgeAct

type arinc_cfg = arinc_node -> ((location * edge) list * arinc_node) list

module type CfgBackward =
sig
  val prev : arinc_node -> ((location * edge) list * arinc_node) list
end

module type CfgForward =
sig
  val next : arinc_node -> ((location * edge) list * arinc_node) list
end

module type CfgBidir =
sig
  include CfgBackward
  include CfgForward
end

module H = BatHashtbl.Make(Arinc_Node)

(* Dumps a statement to the standard output *)
let pstmt stmt = dumpStmt defaultCilPrinter stdout 0 stmt; print_newline ()

let current_node : arinc_node option ref = ref None


let our_arinc_cfg:arinc_cfg*arinc_cfg =
  let cfgF = H.create 113 in
  let cfgB = H.create 113 in

  (* Utility function to add stmt edges to the cfg *)
  let addCfg' t xs f =
    H.add cfgB t (xs,f);
    H.add cfgF f (xs,t);
    Messages.trace "cfg" "done\n\n" in
  let addCfg t (e,f) = addCfg' t [Cil.locUnknown ,e] f in
  let mkEdge fromNode edge toNode = addCfg toNode (edge, fromNode) in
  for i = 0 to 6 do
    mkEdge (PC ([0; i])) (0, Computation 10) (PC [1; i]);
    mkEdge (PC ([1; i])) (0, PeriodicWait) (PC [2; i]);
    mkEdge (PC ([2; i])) (0, WaitingForPeriod) (PC [3; i]);
    mkEdge (PC ([3; i])) (0, SetEvent 0) (PC [4; i]);
    mkEdge (PC ([4; i])) (0, Computation 20) (PC [5; i]);
    mkEdge (PC ([5; i])) (0, ResumeTask 1) (PC [6; i]);
    mkEdge (PC ([6; i])) (0, TimedWait 20) (PC[12;i]);
    mkEdge (PC ([12; i])) (0, WaitingForEndWait) (PC[8;i]);
    mkEdge (PC ([6; i])) (0, WaitEvent 1) (PC [7; i]);
    mkEdge (PC ([7; i])) (0, ResetEvent 1) (PC [8; i]);
    mkEdge (PC ([8; i])) (0, Computation 42) (PC [9; i]);
    mkEdge (PC ([9; i])) (0, SuspendTask 1) (PC [10; i]);
    mkEdge (PC ([10; i])) (0, PeriodicWait) (PC [11; i]);
    mkEdge (PC ([11; i])) (0, WaitingForPeriod) (PC [4; i]);

  done;
  for i = 0 to 13 do
    mkEdge (PC ([i; 0])) (1, SuspendTask 1) (PC [i; 1]);
    mkEdge (PC ([i; 1])) (1, WaitSemaphore 0) (PC [i; 2]);
    mkEdge (PC ([i; 2])) (1, Computation 40) (PC [i; 3]);
    mkEdge (PC ([i; 3])) (1, SignalSemaphore 0) (PC [i; 4]);
    mkEdge (PC ([i; 4])) (1, SetEvent 1) (PC [i; 5]);
    mkEdge (PC ([i; 5])) (1, NOP) (PC [i; 1]);
  done;
  (* Printf.printf "!!!!!!!Edge count %i\n" (List.length (H.find_all cfgB (PC ([9; 4])))); *)
  (* H.iter (fun n (e,t) -> match n,t with PC [a;b], PC[c;d] -> Printf.printf "[%i,%i] -> [%i,%i]\n" a b c d;) cfgF; *)
  H.find_all cfgF, H.find_all cfgB
