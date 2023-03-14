open Prelude
open GoblintCil

module type S = sig
  val transform : (?node:Node.t -> Cil.location -> Queries.ask) -> file -> unit (* modifications are done in-place by CIL :( *)
end

let h = Hashtbl.create 13
let register name (module T : S) = Hashtbl.add h name (module T : S)
let run name =
  let module T = (val try Hashtbl.find h name with Not_found -> failwith @@ "Transformation "^name^" does not exist!") in
  if GobConfig.get_bool "dbg.verbose" then Logs.debug "Starting transformation %s" name;
  T.transform

module PartialEval = struct
  let loc = ref locUnknown (* when we visit an expression, we need the current location -> store at stmts *)
  class visitor (ask: ?node:Node.t -> Cil.location -> Queries.ask) = object
    inherit nopCilVisitor
    method! vstmt s =
      loc := Cilfacade.get_stmtLoc s;
      (* Logs.debug "Set loc at stmt %a to %a" d_stmt s CilType.Location.pretty !loc; *)
      DoChildren
    method! vexpr e =
      let eval e = match Queries.ID.to_int ((ask !loc).Queries.f (Queries.EvalInt e)) with
        | Some i ->
          let e' = integer @@ IntOps.BigIntOps.to_int i in
          Logs.debug "Replacing non-constant expression %a with %a at %a" d_exp e d_exp e' CilType.Location.pretty !loc;
          e'
        | None ->
          Logs.error "Can't replace expression %a at %a" d_exp e CilType.Location.pretty !loc; e
      in
      match e with
      | Const _ -> SkipChildren
      | _ -> ChangeDoChildrenPost (e, eval)
  end
  let transform ask file =
    visitCilFile (new visitor ask) file
end
let _ = register "partial" (module PartialEval)
