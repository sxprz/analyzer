open Prelude.Ana

type t =
  | Lock of LockDomain.Lockset.Lock.t
  | Unlock of LockDomain.Addr.t
  | Escape of EscapeDomain.EscapedVars.t
  | EnterMultiThreaded
  | SplitBranch of exp * bool (** Used to simulate old branch-based split. *)
  | AssignSpawnedThread of lval * ThreadIdDomain.Thread.t (** Assign spawned thread's ID to lval. *)
  | Access of {var_opt: CilType.Varinfo.t option; kind: AccessKind.t} (** Access varinfo (unknown if None). *)
  | Assign of {lval: CilType.Lval.t; exp: CilType.Exp.t} (** Used to simulate old [ctx.assign]. *)

let pp ppf e =
  ppf
  |> match e with
  | Lock m -> dprintf "Lock %a" LockDomain.Lockset.Lock.pp m
  | Unlock m -> dprintf "Unlock %a" LockDomain.Addr.pp m
  | Escape escaped -> dprintf "Escape %a" EscapeDomain.EscapedVars.pp escaped
  | EnterMultiThreaded -> text "EnterMultiThreaded"
  | SplitBranch (exp, tv) -> dprintf "SplitBranch (%a, %B)" d_exp exp tv
  | AssignSpawnedThread (lval, tid) -> dprintf "AssignSpawnedThread (%a, %a)" d_lval lval ThreadIdDomain.Thread.pp tid
  | Access {var_opt; kind} -> dprintf "Access {var_opt=%a, kind=%a}" (docOpt (fun v ppf -> CilType.Varinfo.pp ppf v)) var_opt AccessKind.pp kind
  | Assign {lval; exp} -> dprintf "Assign {lval=%a, exp=%a}" CilType.Lval.pp lval CilType.Exp.pp exp
