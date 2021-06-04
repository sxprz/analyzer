open Prelude.Ana
open Analyses
open GobConfig
open BaseUtil
module Q = Queries

module OctApronComponents = OctApronDomain.OctApronComponents
module AD = OctApronDomain.D2
module A = OctApronDomain.A
module Man = OctApronDomain.Man
open Apron

open CommonPriv


module type S =
sig
  module D: Lattice.S
  module G: Lattice.S

  val startstate: unit -> D.t

  val read_global: Q.ask -> (varinfo -> G.t) -> OctApronComponents (D).t -> varinfo -> varinfo -> OctApronComponents (D).t

  (* [invariant]: Check if we should avoid producing a side-effect, such as updates to
   * the state when following conditional guards. *)
  val write_global: ?invariant:bool -> Q.ask -> (varinfo -> G.t) -> (varinfo -> G.t -> unit) -> OctApronComponents (D).t -> varinfo -> varinfo -> OctApronComponents (D).t

  val lock: Q.ask -> (varinfo -> G.t) -> OctApronComponents (D).t -> LockDomain.Addr.t -> OctApronComponents (D).t
  val unlock: Q.ask -> (varinfo -> G.t) -> (varinfo -> G.t -> unit) -> OctApronComponents (D).t -> LockDomain.Addr.t -> OctApronComponents (D).t

  val sync: Q.ask -> (varinfo -> G.t) -> (varinfo -> G.t -> unit) -> OctApronComponents (D).t -> [`Normal | `Join | `Return | `Init | `Thread] -> OctApronComponents (D).t

  val escape: Q.ask -> (varinfo -> G.t) -> (varinfo -> G.t -> unit) -> OctApronComponents (D).t -> EscapeDomain.EscapedVars.t -> OctApronComponents (D).t
  val enter_multithreaded: Q.ask -> (varinfo -> G.t) -> (varinfo -> G.t -> unit) -> OctApronComponents (D).t -> OctApronComponents (D).t
  val threadenter: Q.ask -> (varinfo -> G.t) -> OctApronComponents (D).t -> OctApronComponents (D).t

  val init: unit -> unit
  val finalize: unit -> unit
end


module Dummy: S =
struct
  module D = Lattice.Unit
  module G = Lattice.Unit

  let startstate () = ()

  let read_global ask getg st g x = st
  let write_global ?(invariant=false) ask getg sideg st g x = st

  let lock ask getg st m = st
  let unlock ask getg sideg st m = st

  let sync ask getg sideg st reason = st

  let escape ask getg sideg st escaped = st
  let enter_multithreaded ask getg sideg st = st
  let threadenter ask getg st = st

  let init () = ()
  let finalize () = ()
end

(** Protection-Based Reading. *)
module ProtectionBasedPriv: S =
struct
  open Protection

  module P =
  struct
    include MustVars
    let name () = "P"
  end
  module D = P

  module G = AD

  let global_varinfo = RichVarinfo.single ~name:"OCTAPRON_GLOBAL"

  let var_local g = Var.of_string g.vname
  let var_unprot g = Var.of_string (g.vname ^ "#unprot")
  let var_prot g = Var.of_string (g.vname ^ "#prot")

  let startstate () = P.empty ()

  let read_global ask getg (st: OctApronComponents (D).t) g x =
    let oct = st.oct in
    let g_local_var = var_local g in
    let x_var = Var.of_string x.vname in
    let oct_local =
      if AD.mem_var oct g_local_var then
        AD.assign_var' oct x_var g_local_var
      else
        AD.bot ()
    in
    let oct_local' =
      if P.mem g st.priv then
        oct_local
      else if is_unprotected ask g then (
        let g_unprot_var = var_unprot g in
        let oct_unprot = AD.add_vars_int oct [g_unprot_var] in
        let oct_unprot = AD.assign_var' oct_unprot x_var g_unprot_var in
        let oct_unprot' = AD.remove_vars oct_unprot [g_unprot_var] in (* unlock *)
        (* add, assign from, remove is not equivalent to forget if g#unprot already existed and had some relations *)
        AD.join oct_local oct_unprot'
      )
      else (
        let g_prot_var = var_prot g in
        let oct_prot = AD.add_vars_int oct [g_prot_var] in
        let oct_prot = AD.assign_var' oct_prot x_var g_prot_var in
        AD.join oct_local oct_prot
      )
    in
    let oct_local' = AD.meet oct_local' (getg (global_varinfo ())) in
    {st with oct = oct_local'}

  let write_global ?(invariant=false) ask getg sideg (st: OctApronComponents (D).t) g x =
    let oct = st.oct in
    let g_local_var = var_local g in
    let g_unprot_var = var_unprot g in
    let x_var = Var.of_string x.vname in
    let oct_local = AD.add_vars_int oct [g_local_var] in
    let oct_local = AD.assign_var' oct_local g_local_var x_var in
    let oct_side = AD.add_vars_int oct_local [g_unprot_var] in
    let oct_side = AD.assign_var' oct_side g_unprot_var g_local_var in
    let oct_side = AD.keep_vars oct_side [g_unprot_var] in (* TODO: don't remove g#prot-s, other g#unprot-s *)
    sideg (global_varinfo ()) oct_side;
    let st' =
      if is_unprotected ask g then
        st (* add, assign, remove gives original local state *)
      else
        {oct = oct_local; priv = P.add g st.priv}
    in
    let oct_local' = AD.meet st'.oct (getg (global_varinfo ())) in
    {st' with oct = oct_local'}

  let lock ask getg (st: OctApronComponents (D).t) m = st

  let unlock ask getg sideg (st: OctApronComponents (D).t) m =
    let oct = st.oct in
    let p = st.priv in
    let (p_remove, p') = P.partition (fun g -> is_unprotected_without ask g m) p in
    (* TODO: avoid all globals *)
    let all_gs =
      foldGlobals !Cilfacade.current_file (fun acc global ->
        match global with
        | GVar (vi, _, _) ->
          vi :: acc
          (* TODO: what about GVarDecl? *)
        | _ -> acc
      ) []
    in
    (* not locally may-written globals couldn't be parallel assigned for side effect anyway *)
    let may_local_gs = List.filter (fun g ->
        AD.mem_var oct (var_local g)
      ) all_gs
    in
    let big_omega_gs =
      (* all locally must-written globals are always included *)
      let certain_gs = List.filter (fun g -> P.mem g p) may_local_gs in
      (* all protected but not locally must-written globals have a choice *)
      let choice_gs = List.filter (fun g ->
          not (P.mem g p) && is_protected_by ask m g
        ) may_local_gs
      in
      choice_gs
      |> List.map (fun _ -> [true; false])
      |> List.n_cartesian_product (* TODO: exponential! *)
      |> List.map (fun omega ->
          (* list globals where omega is true *)
          List.fold_left2 (fun acc g omega_g ->
            if omega_g then
              g :: acc
            else
              acc
          ) certain_gs choice_gs omega
        )
    in
    let oct_side = List.fold_left (fun acc omega_gs ->
        let g_prot_vars = List.map var_prot omega_gs in
        let g_local_vars = List.map var_local omega_gs in
        let oct_side1 = AD.add_vars_int oct g_prot_vars in
        let oct_side1 = AD.parallel_assign_vars oct_side1 g_prot_vars g_local_vars in
        AD.join acc oct_side1
      ) (AD.bot ()) big_omega_gs
    in
    let oct_side = AD.keep_vars oct_side (List.map var_prot may_local_gs) in (* TODO: don't remove g#unprot-s, other g#prot-s *)
    sideg (global_varinfo ()) oct_side;
    let oct_local = AD.remove_vars oct (List.map var_local (P.elements p_remove)) in
    let oct_local' = AD.meet oct_local (getg (global_varinfo ())) in
    {st with oct = oct_local'; priv = p'}

  let sync ask getg sideg (st: OctApronComponents (D).t) reason =
    match reason with
    | `Return -> (* required for thread return *)
      (* TODO: implement? *)
      begin match ThreadId.get_current ask with
        | `Lifted x (* when CPA.mem x st.cpa *) ->
          st
        | _ ->
          st
      end
    | `Normal
    | `Join (* TODO: no problem with branched thread creation here? *)
    | `Init
    | `Thread ->
      st

  let escape ask getg sideg (st: OctApronComponents (D).t) escaped =
    EscapeDomain.EscapedVars.fold (fun x acc ->
        (* TODO: implement *)
        st
      ) escaped st

  let enter_multithreaded ask getg sideg (st: OctApronComponents (D).t) =
    (* TODO: implement *)
    {st with oct = AD.meet st.oct (getg (global_varinfo ())); priv = startstate ()}

  let threadenter ask getg (st: OctApronComponents (D).t): OctApronComponents (D).t =
    {oct = getg (global_varinfo ()); priv = startstate ()}

  let init () = ()
  let finalize () = ()
end

(** Write-Centered Reading. *)
module WriteCenteredPriv: S =
struct
  open Locksets

  open WriteCenteredD
  module D = Lattice.Prod (W) (P)

  module G = AD

  let global_varinfo = RichVarinfo.single ~name:"OCTAPRON_GLOBAL"

  let startstate () = (W.bot (), P.top ())

  let lockset_init = Lockset.top ()

  (* TODO: distr_init? *)

  let restrict_globals oct =
    match !MyCFG.current_node with
    | Some node ->
      let fd = MyCFG.getFun node in
      if M.tracing then M.trace "apronpriv" "restrict_globals %s\n" fd.svar.vname;
      (* TODO: avoid *)
      let vars =
        foldGlobals !Cilfacade.current_file (fun acc global ->
          match global with
          | GVar (vi, _, _) ->
            vi :: acc
            (* TODO: what about GVarDecl? *)
          | _ -> acc
        ) []
      in
      let to_keep = List.map (fun v -> v.vname) vars in
      let oct' = A.copy Man.mgr oct in
      AD.remove_all_but_with oct' to_keep;
      oct'
    | None ->
      (* TODO: when does this happen? *)
      if M.tracing then M.trace "apronpriv" "restrict_globals -\n";
      AD.bot ()

  let read_global ask getg (st: OctApronComponents (D).t) g x =
    let s = current_lockset ask in
    let (w, p) = st.priv in
    let p_g = P.find g p in
    (* TODO: implement *)
    let oct' = AD.add_vars st.oct ([g.vname], []) in
    let oct' = A.assign_texpr Man.mgr oct' (Var.of_string x.vname) (Texpr1.var (A.env oct') (Var.of_string g.vname)) None in (* TODO: unsound *)
    {st with oct = oct'}

  let write_global ?(invariant=false) ask getg sideg (st: OctApronComponents (D).t) g x =
    let s = current_lockset ask in
    let (w, p) = st.priv in
    let w' = W.add g (MinLocksets.singleton s) w in
    let p' = P.add g (MinLocksets.singleton s) p in
    let p' = P.map (fun s' -> MinLocksets.add s s') p' in
    (* TODO: implement *)
    let oct' = AD.add_vars st.oct ([g.vname], []) in
    let oct' = A.assign_texpr Man.mgr oct' (Var.of_string g.vname) (Texpr1.var (A.env oct') (Var.of_string x.vname)) None in (* TODO: unsound? *)
    sideg (global_varinfo ()) (restrict_globals oct');
    {st with oct = oct'; priv = (w', p')}

  let lock ask getg (st: OctApronComponents (D).t) m = st

  let unlock ask getg sideg (st: OctApronComponents (D).t) m =
    let s = Lockset.remove m (current_lockset ask) in
    let (w, p) = st.priv in
    let p' = P.map (fun s' -> MinLocksets.add s s') p in
    (* TODO: implement *)
    sideg (global_varinfo ()) (restrict_globals st.oct);
    {st with priv = (w, p')}

  let sync ask getg sideg (st: OctApronComponents (D).t) reason =
    match reason with
    | `Return -> (* required for thread return *)
      (* TODO: implement? *)
      begin match ThreadId.get_current ask with
        | `Lifted x (* when CPA.mem x st.cpa *) ->
          st
        | _ ->
          st
      end
    | `Normal
    | `Join (* TODO: no problem with branched thread creation here? *)
    | `Init
    | `Thread ->
      st

  let escape ask getg sideg (st: OctApronComponents (D).t) escaped =
    let s = current_lockset ask in
    EscapeDomain.EscapedVars.fold (fun x acc ->
        let (w, p) = st.priv in
        let p' = P.add x (MinLocksets.singleton s) p in
        (* TODO: implement *)
        {st with priv = (w, p')}
      ) escaped st

  let enter_multithreaded ask getg sideg (st: OctApronComponents (D).t) =
    (* TODO: implement *)
    {st with oct = AD.meet st.oct (getg (global_varinfo ()))}

  let threadenter ask getg (st: OctApronComponents (D).t): OctApronComponents (D).t =
    {oct = getg (global_varinfo ()); priv = startstate ()}

  let init () = ()
  let finalize () = ()
end


module TracingPriv (Priv: S): S with module D = Priv.D =
struct
  include Priv

  module OctApronComponents = OctApronComponents (D)

  let read_global ask getg st g x =
    if M.tracing then M.traceli "apronpriv" "read_global %a %a\n" d_varinfo g d_varinfo x;
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let r = Priv.read_global ask getg st g x in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let write_global ?invariant ask getg sideg st g x =
    if M.tracing then M.traceli "apronpriv" "write_global %a %a\n" d_varinfo g d_varinfo x;
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let sideg x v =
      if M.tracing then M.trace "apronpriv" "sideg %a %a\n" d_varinfo x G.pretty v;
      sideg x v
    in
    let r = write_global ?invariant ask getg sideg st g x in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let lock ask getg st m =
    if M.tracing then M.traceli "apronpriv" "lock %a\n" LockDomain.Addr.pretty m;
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let r = lock ask getg st m in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let unlock ask getg sideg st m =
    if M.tracing then M.traceli "apronpriv" "unlock %a\n" LockDomain.Addr.pretty m;
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let sideg x v =
      if M.tracing then M.trace "apronpriv" "sideg %a %a\n" d_varinfo x G.pretty v;
      sideg x v
    in
    let r = unlock ask getg sideg st m in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let enter_multithreaded ask getg sideg st =
    if M.tracing then M.traceli "apronpriv" "enter_multithreaded\n";
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let sideg x v =
      if M.tracing then M.trace "apronpriv" "sideg %a %a\n" d_varinfo x G.pretty v;
      sideg x v
    in
    let r = enter_multithreaded ask getg sideg st in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let threadenter ask getg st =
    if M.tracing then M.traceli "apronpriv" "threadenter\n";
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let r = threadenter ask getg st in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r

  let sync ask getg sideg st reason =
    if M.tracing then M.traceli "apronpriv" "sync\n";
    if M.tracing then M.trace "apronpriv" "st: %a\n" OctApronComponents.pretty st;
    let getg x =
      let r = getg x in
      if M.tracing then M.trace "apronpriv" "getg %a -> %a\n" d_varinfo x G.pretty r;
      r
    in
    let sideg x v =
      if M.tracing then M.trace "apronpriv" "sideg %a %a\n" d_varinfo x G.pretty v;
      sideg x v
    in
    let r = sync ask getg sideg st reason in
    if M.tracing then M.traceu "apronpriv" "-> %a\n" OctApronComponents.pretty r;
    r
end


let priv_module: (module S) Lazy.t =
  lazy (
    let module Priv: S =
      (val match get_string "exp.octapron.privatization" with
        | "dummy" -> (module Dummy: S)
        | "protection" -> (module ProtectionBasedPriv)
        | "write" -> (module WriteCenteredPriv)
        | _ -> failwith "exp.octapron.privatization: illegal value"
      )
    in
    let module Priv = TracingPriv (Priv) in
    (module Priv)
  )

let get_priv (): (module S) =
  Lazy.force priv_module
