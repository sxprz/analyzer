open Prelude.Ana
open GoblintCil

module M = Messages
module VD = BaseDomain.VD
module ID = ValueDomain.ID
module FD = ValueDomain.FD
module AD = ValueDomain.AD
module BI = IntOps.BigIntOps

module type Eval =
sig
  module D: Lattice.S
  module V: Analyses.SpecSysVar
  module G: Lattice.S

  val eval_rv: Queries.ask -> (V.t -> G.t) -> D.t -> exp -> VD.t
  val eval_rv_address: Queries.ask -> (V.t -> G.t) -> D.t -> exp -> VD.t
  val eval_lv: Queries.ask -> (V.t -> G.t) -> D.t -> lval -> AD.t

  val refine_lv_fallback: (D.t, G.t, _, V.t) Analyses.ctx -> Queries.ask -> (V.t -> G.t) -> D.t -> lval -> VD.t -> bool -> D.t
  val refine_lv: (D.t, G.t, _, V.t) Analyses.ctx -> Queries.ask -> (V.t -> G.t) -> D.t -> 'a -> lval -> VD.t -> (unit -> 'a -> doc) -> exp -> D.t

  val id_meet_down: old:ID.t -> c:ID.t -> ID.t
  val fd_meet_down: old:FD.t -> c:FD.t -> FD.t
end

module Make (Eval: Eval) =
struct
  open Eval

  let unop_ID = function
    | Neg  -> ID.neg
    | BNot -> ID.bitnot
    | LNot -> ID.lognot

  let unop_FD = function
    | Neg  -> FD.neg
    (* other unary operators are not implemented on float values *)
    | _ -> (fun c -> FD.top_of (FD.get_fkind c))

  let is_some_bot x =
    match x with
    | `Bot -> false (* HACK: bot is here due to typing conflict (we do not cast appropriately) *)
    | _ -> VD.is_bot_value x

  let invariant_fallback ctx a (gs:V.t -> G.t) st exp tv =
    (* We use a recursive helper function so that x != 0 is false can be handled
    * as x == 0 is true etc *)
    let rec helper (op: binop) (lval: lval) (value: VD.t) (tv: bool) =
      match (op, lval, value, tv) with
      (* The true-branch where x == value: *)
      | Eq, x, value, true ->
        if M.tracing then M.tracec "invariant" "Yes, %a equals %a\n" d_lval x VD.pretty value;
        (match value with
        | `Int n ->
          let ikind = Cilfacade.get_ikind_exp (Lval lval) in
          Some (x, `Int (ID.cast_to ikind n))
        | _ -> Some(x, value))
      (* The false-branch for x == value: *)
      | Eq, x, value, false -> begin
          match value with
          | `Int n -> begin
              match ID.to_int n with
              | Some n ->
                (* When x != n, we can return a singleton exclusion set *)
                if M.tracing then M.tracec "invariant" "Yes, %a is not %s\n" d_lval x (BI.to_string n);
                let ikind = Cilfacade.get_ikind_exp (Lval lval) in
                Some (x, `Int (ID.of_excl_list ikind [n]))
              | None -> None
            end
          | `Address n -> begin
              if M.tracing then M.tracec "invariant" "Yes, %a is not %a\n" d_lval x AD.pretty n;
              match eval_rv_address a gs st (Lval x) with
              | `Address a when AD.is_definite n ->
                Some (x, `Address (AD.diff a n))
              | `Top when AD.is_null n ->
                Some (x, `Address AD.not_null)
              | v ->
                if M.tracing then M.tracec "invariant" "No address invariant for: %a != %a\n" VD.pretty v AD.pretty n;
                None
            end
          (* | `Address a -> Some (x, value) *)
          | _ ->
            (* We can't say anything else, exclusion sets are finite, so not
            * being in one means an infinite number of values *)
            if M.tracing then M.tracec "invariant" "Failed! (not a definite value)\n";
            None
        end
      | Ne, x, value, _ -> helper Eq x value (not tv)
      | Lt, x, value, _ -> begin
          match value with
          | `Int n -> begin
              let ikind = Cilfacade.get_ikind_exp (Lval lval) in
              let n = ID.cast_to ikind n in
              let range_from x = if tv then ID.ending ikind (BI.sub x BI.one) else ID.starting ikind x in
              let limit_from = if tv then ID.maximal else ID.minimal in
              match limit_from n with
              | Some n ->
                if M.tracing then M.tracec "invariant" "Yes, success! %a is not %s\n\n" d_lval x (BI.to_string n);
                Some (x, `Int (range_from n))
              | None -> None
            end
          | _ -> None
        end
      | Le, x, value, _ -> begin
          match value with
          | `Int n -> begin
              let ikind = Cilfacade.get_ikind_exp (Lval lval) in
              let n = ID.cast_to ikind n in
              let range_from x = if tv then ID.ending ikind x else ID.starting ikind (BI.add x BI.one) in
              let limit_from = if tv then ID.maximal else ID.minimal in
              match limit_from n with
              | Some n ->
                if M.tracing then M.tracec "invariant" "Yes, success! %a is not %s\n\n" d_lval x (BI.to_string n);
                Some (x, `Int (range_from n))
              | None -> None
            end
          | _ -> None
        end
      | Gt, x, value, _ -> helper Le x value (not tv)
      | Ge, x, value, _ -> helper Lt x value (not tv)
      | _ ->
        if M.tracing then M.trace "invariant" "Failed! (operation not supported)\n\n";
        None
    in
    if M.tracing then M.traceli "invariant" "assume expression %a is %B\n" d_exp exp tv;
    let null_val typ =
      match Cil.unrollType typ with
      | TPtr _                    -> `Address AD.null_ptr
      | TEnum({ekind=_;_},_)
      | _                         -> `Int (ID.of_int (Cilfacade.get_ikind typ) BI.zero)
    in
    let rec derived_invariant exp tv =
      let switchedOp = function Lt -> Gt | Gt -> Lt | Le -> Ge | Ge -> Le | x -> x in (* a op b <=> b (switchedOp op) b *)
      match exp with
      (* Since we handle not only equalities, the order is important *)
      | BinOp(op, Lval x, rval, typ) -> helper op x (VD.cast (Cilfacade.typeOfLval x) (eval_rv a gs st rval)) tv
      | BinOp(op, rval, Lval x, typ) -> derived_invariant (BinOp(switchedOp op, Lval x, rval, typ)) tv
      | BinOp(op, CastE (t1, c1), CastE (t2, c2), t) when (op = Eq || op = Ne) && typeSig t1 = typeSig t2 && VD.is_safe_cast t1 (Cilfacade.typeOf c1) && VD.is_safe_cast t2 (Cilfacade.typeOf c2)
        -> derived_invariant (BinOp (op, c1, c2, t)) tv
      | BinOp(op, CastE (TInt (ik, _) as t1, Lval x), rval, typ) ->
        (match eval_rv a gs st (Lval x) with
        | `Int v ->
          (* This is tricky: It it is not sufficient to check that ID.cast_to_ik v = v
            * If there is one domain that knows this to be true and the other does not, we
            * should still impose the invariant. E.g. i -> ([1,5]; Not {0}[byte]) *)
          if VD.is_safe_cast t1 (Cilfacade.typeOfLval x) then
            derived_invariant (BinOp (op, Lval x, rval, typ)) tv
          else
            None
        | _ -> None)
      | BinOp(op, rval, CastE (TInt (_, _) as ti, Lval x), typ) ->
        derived_invariant (BinOp (switchedOp op, CastE(ti, Lval x), rval, typ)) tv
      (* Cases like if (x) are treated like if (x != 0) *)
      | Lval x ->
        (* There are two correct ways of doing it: "if ((int)x != 0)" or "if (x != (typeof(x))0))"
        * Because we try to avoid casts (and use a more precise address domain) we use the latter *)
        helper Ne x (null_val (Cilfacade.typeOf exp)) tv
      | UnOp (LNot,uexp,typ) -> derived_invariant uexp (not tv)
      | _ ->
        if M.tracing then M.tracec "invariant" "Failed! (expression %a not understood)\n\n" d_plainexp exp;
        None
    in
    match derived_invariant exp tv with
    | Some (lval, value) ->
      refine_lv_fallback ctx a gs st lval value tv
    | None ->
      if M.tracing then M.traceu "invariant" "Doing nothing.\n";
      M.debug ~category:Analyzer "Invariant failed: expression \"%a\" not understood." d_plainexp exp;
      st

  let invariant ctx a gs st exp tv: D.t =
    let fallback reason st =
      if M.tracing then M.tracel "inv" "Can't handle %a.\n%s\n" d_plainexp exp reason;
      invariant_fallback ctx a gs st exp tv
    in
    (* inverse values for binary operation a `op` b == c *)
    (* ikind is the type of a for limiting ranges of the operands a, b. The only binops which can have different types for a, b are Shiftlt, Shiftrt (not handled below; don't use ikind to limit b there). *)
    let inv_bin_int (a, b) ikind c op =
      let warn_and_top_on_zero x =
        if GobOption.exists (BI.equal BI.zero) (ID.to_int x) then
          (M.error ~category:M.Category.Integer.div_by_zero ~tags:[CWE 369] "Must Undefined Behavior: Second argument of div or mod is 0, continuing with top";
          ID.top_of ikind)
        else
          x
      in
      let meet_bin a' b'  = id_meet_down ~old:a ~c:a', id_meet_down ~old:b ~c:b' in
      let meet_com oi = (* commutative *)
        try
          meet_bin (oi c b) (oi c a)
        with
          IntDomain.ArithmeticOnIntegerBot _ -> raise Analyses.Deadcode in
      let meet_non oi oo = (* non-commutative *)
        try
          meet_bin (oi c b) (oo a c)
        with IntDomain.ArithmeticOnIntegerBot _ -> raise Analyses.Deadcode in
      match op with
      | PlusA  -> meet_com ID.sub
      | Mult   ->
        (* Only multiplication with odd numbers is an invertible operation in (mod 2^n) *)
        (* refine x by information about y, using x * y == c *)
        let refine_by x y = (match ID.to_int y with
            | None -> x
            | Some v when BI.equal (BI.rem v (BI.of_int 2)) BI.zero (* v % 2 = 0 *) -> x (* A refinement would still be possible here, but has to take non-injectivity into account. *)
            | Some v (* when Int64.rem v 2L = 1L *) -> id_meet_down ~old:x ~c:(ID.div c y)) (* Div is ok here, c must be divisible by a and b *)
        in
        (refine_by a b, refine_by b a)
      | MinusA -> meet_non ID.add ID.sub
      | Div    ->
        (* If b must be zero, we have must UB *)
        let b = warn_and_top_on_zero b in
        (* Integer division means we need to add the remainder, so instead of just `a = c*b` we have `a = c*b + a%b`.
        * However, a%b will give [-b+1, b-1] for a=top, but we only want the positive/negative side depending on the sign of c*b.
        * If c*b = 0 or it can be positive or negative, we need the full range for the remainder. *)
        let rem =
          let is_pos = ID.to_bool @@ ID.gt (ID.mul b c) (ID.of_int ikind BI.zero) = Some true in
          let is_neg = ID.to_bool @@ ID.lt (ID.mul b c) (ID.of_int ikind BI.zero) = Some true in
          let full = ID.rem a b in
          if is_pos then ID.meet (ID.starting ikind BI.zero) full
          else if is_neg then ID.meet (ID.ending ikind BI.zero) full
          else full
        in
        meet_bin (ID.add (ID.mul b c) rem) (ID.div (ID.sub a rem) c)
      | Mod    -> (* a % b == c *)
        (* If b must be zero, we have must UB *)
        let b = warn_and_top_on_zero b in
        (* a' = a/b*b + c and derived from it b' = (a-c)/(a/b)
        * The idea is to formulate a' as quotient * divisor + remainder. *)
        let a' = ID.add (ID.mul (ID.div a b) b) c in
        let b' = ID.div (ID.sub a c) (ID.div a b) in
        (* However, for [2,4]%2 == 1 this only gives [3,4].
        * If the upper bound of a is divisible by b, we can also meet with the result of a/b*b - c to get the precise [3,3].
        * If b is negative we have to look at the lower bound. *)
        let is_divisible bound =
          match bound a with
          | Some ba -> ID.rem (ID.of_int ikind ba) b |> ID.to_int = Some BI.zero
          | None -> false
        in
        let max_pos = match ID.maximal b with None -> true | Some x -> BI.compare x BI.zero >= 0 in
        let min_neg = match ID.minimal b with None -> true | Some x -> BI.compare x BI.zero < 0 in
        let implies a b = not a || b in
        let a'' =
          if implies max_pos (is_divisible ID.maximal) && implies min_neg (is_divisible ID.minimal) then
            ID.meet a' (ID.sub (ID.mul (ID.div a b) b) c)
          else a'
        in
        let a''' =
          (* if both b and c are definite, we can get a precise value in the congruence domain *)
          if ID.is_int b && ID.is_int c then
            (* a%b == c  -> a: c+bℤ *)
            let t = ID.of_congruence ikind ((BatOption.get @@ ID.to_int c), (BatOption.get @@ ID.to_int b)) in
            ID.meet a'' t
          else a''
        in
        meet_bin a''' b'
      | Eq | Ne as op ->
        let both x = x, x in
        let m = ID.meet a b in
        (match op, ID.to_bool c with
        | Eq, Some true
        | Ne, Some false -> both m (* def. equal: if they compare equal, both values must be from the meet *)
        | Eq, Some false
        | Ne, Some true -> (* def. unequal *)
          (* Both values can not be in the meet together, but it's not sound to exclude the meet from both.
            * e.g. a=[0,1], b=[1,2], meet a b = [1,1], but (a != b) does not imply a=[0,0], b=[2,2] since others are possible: a=[1,1], b=[2,2]
            * Only if a is a definite value, we can exclude it from b: *)
          let excl a b = match ID.to_int a with Some x -> ID.of_excl_list ikind [x] | None -> b in
          let a' = excl b a in
          let b' = excl a b in
          if M.tracing then M.tracel "inv" "inv_bin_int: unequal: %a and %a; ikind: %a; a': %a, b': %a\n" ID.pretty a ID.pretty b d_ikind ikind ID.pretty a' ID.pretty b';
          meet_bin a' b'
        | _, _ -> a, b
        )
      | Lt | Le | Ge | Gt as op ->
        let pred x = BI.sub x BI.one in
        let succ x = BI.add x BI.one in
        (match ID.minimal a, ID.maximal a, ID.minimal b, ID.maximal b with
        | Some l1, Some u1, Some l2, Some u2 ->
          (* if M.tracing then M.tracel "inv" "Op: %s, l1: %Ld, u1: %Ld, l2: %Ld, u2: %Ld\n" (show_binop op) l1 u1 l2 u2; *)
          (match op, ID.to_bool c with
            | Le, Some true
            | Gt, Some false -> meet_bin (ID.ending ikind u2) (ID.starting ikind l1)
            | Ge, Some true
            | Lt, Some false -> meet_bin (ID.starting ikind l2) (ID.ending ikind u1)
            | Lt, Some true
            | Ge, Some false -> meet_bin (ID.ending ikind (pred u2)) (ID.starting ikind (succ l1))
            | Gt, Some true
            | Le, Some false -> meet_bin (ID.starting ikind (succ l2)) (ID.ending ikind (pred u1))
            | _, _ -> a, b)
        | _ -> a, b)
      | BOr | BXor as op->
        if M.tracing then M.tracel "inv" "Unhandled operator %a\n" d_binop op;
        (* Be careful: inv_exp performs a meet on both arguments of the BOr / BXor. *)
        a, b
      | LAnd ->
        if ID.to_bool c = Some true then
          meet_bin c c
        else
          a, b
      | op ->
        if M.tracing then M.tracel "inv" "Unhandled operator %a\n" d_binop op;
        a, b
    in
    let inv_bin_float (a, b) c op =
      let open Stdlib in
      let meet_bin a' b'  = fd_meet_down ~old:a ~c:a', fd_meet_down ~old:b ~c:b' in
      (* Refining the abstract values based on branching is roughly based on the idea in [Symbolic execution of floating-point computations](https://hal.inria.fr/inria-00540299/document)
        However, their approach is only applicable to the "nearest" rounding mode. Here we use a more general approach covering all possible rounding modes and therefore
        use the actual `pred c_min`/`succ c_max` for the outer-bounds instead of the middles between `c_min` and `pred c_min`/`c_max` and `succ c_max` as suggested in the paper.
        This also removes the necessity of computing those expressions with higher precise than in the concrete.
      *)
      try
        match op with
        | PlusA  ->
          (* A + B = C, \forall a \in A. a + b_min > pred c_min \land a + b_max < succ c_max
              \land a + b_max > pred c_min \land a + b_min < succ c_max
            \rightarrow A = [min(pred c_min - b_min, pred c_min - b_max), max(succ c_max - b_max, succ c_max - b_min)]
            \rightarrow A = [pred c_min - b_max, succ c_max - b_min]
          *)
          let reverse_add v v' = (match FD.minimal c, FD.maximal c, FD.minimal v, FD.maximal v with
              | Some c_min, Some c_max, Some v_min, Some v_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let l = Float.pred c_min -. v_max in
                let h =  Float.succ c_max -. v_min in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> v') in
          meet_bin (reverse_add b a) (reverse_add a b)
        | MinusA ->
          (* A - B = C \ forall a \in A. a - b_max > pred c_min \land a - b_min < succ c_max
              \land a - b_min > pred c_min \land a - b_max < succ c_max
            \rightarrow A = [min(pred c_min + b_max, pred c_min + b_min), max(succ c_max + b_max, succ c_max + b_max)]
            \rightarrow A = [pred c_min + b_min, succ c_max + b_max]
          *)
          let a' = (match FD.minimal c, FD.maximal c, FD.minimal b, FD.maximal b with
              | Some c_min, Some c_max, Some b_min, Some b_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let l = Float.pred c_min +. b_min in
                let h =  Float.succ c_max +. b_max in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> a) in
          (* A - B = C \ forall b \in B. a_min - b > pred c_min \land a_max - b < succ c_max
              \land a_max - b > pred c_min \land a_min - b < succ c_max
            \rightarrow B = [min(a_max - succ c_max, a_min - succ c_max), max(a_min - pred c_min, a_max - pred c_min)]
            \rightarrow B = [a_min - succ c_max, a_max - pred c_min]
          *)
          let b' = (match FD.minimal c, FD.maximal c, FD.minimal a, FD.maximal a with
              | Some c_min, Some c_max, Some a_min, Some a_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let l = a_min -. Float.succ c_max in
                let h =  a_max -. Float.pred c_min in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> b) in
          meet_bin a'  b'
        | Mult   ->
          (* A * B = C \forall a \in A, a > 0. a * b_min > pred c_min \land a * b_max < succ c_max
            A * B = C \forall a \in A, a < 0. a * b_max > pred c_min \land a * b_min < succ c_max
            (with negative b reversed <>)
            \rightarrow A = [min(pred c_min / b_min, pred c_min / b_max, succ c_max / b_min, succ c_max /b_max),
                              max(succ c_max / b_min, succ c_max /b_max, pred c_min / b_min, pred c_min / b_max)]
          *)
          let reverse_mul v v' = (match FD.minimal c, FD.maximal c, FD.minimal v, FD.maximal v with
              | Some c_min, Some c_max, Some v_min, Some v_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let v1, v2, v3, v4 = (Float.pred c_min /. v_min), (Float.pred c_min /. v_max), (Float.succ c_max /. v_min), (Float.succ c_max /. v_max) in
                let l = Float.min (Float.min v1 v2) (Float.min v3 v4) in
                let h =  Float.max (Float.max v1 v2) (Float.max v3 v4) in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> v') in
          meet_bin (reverse_mul b a) (reverse_mul a b)
        | Div ->
          (* A / B = C \forall a \in A, a > 0, b_min > 1. a / b_max > pred c_min \land a / b_min < succ c_max
            A / B = C \forall a \in A, a < 0, b_min > 1. a / b_min > pred c_min \land a / b_max < succ c_max
            A / B = C \forall a \in A, a > 0, 0 < b_min, b_max < 1. a / b_max > pred c_min \land a / b_min < succ c_max
            A / B = C \forall a \in A, a < 0, 0 < b_min, b_max < 1. a / b_min > pred c_min \land a / b_max < succ c_max
            ... same for negative b
            \rightarrow A = [min(b_max * pred c_min, b_min * pred c_min, b_min * succ c_max, b_max * succ c_max),
                              max(b_max * succ c_max, b_min * succ c_max, b_max * pred c_min, b_min * pred c_min)]
          *)
          let a' = (match FD.minimal c, FD.maximal c, FD.minimal b, FD.maximal b with
              | Some c_min, Some c_max, Some b_min, Some b_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let v1, v2, v3, v4 = (Float.pred c_min *. b_max), (Float.pred c_min *. b_min), (Float.succ c_max *. b_max), (Float.succ c_max *. b_min) in
                let l = Float.min (Float.min v1 v2) (Float.min v3 v4) in
                let h =  Float.max (Float.max v1 v2) (Float.max v3 v4) in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> a) in
          (* A / B = C \forall b \in B, b > 0, a_min / b > pred c_min \land a_min / b < succ c_max
              \land a_max / b > pred c_min \land a_max / b < succ c_max
            A / B = C \forall b \in B, b < 0, a_min / b > pred c_min \land a_min / b < succ c_max
              \land a_max / b > pred c_min \land a_max / b < succ c_max
            \rightarrow (b != 0) B = [min(a_min / succ c_max, a_max / succ c_max, a_min / pred c_min, a_max / pred c_min),
                                      max(a_min / pred c_min, a_max / pred c_min, a_min / succ c_max, a_max / succ c_max)]
          *)
          let b' = (match FD.minimal c, FD.maximal c, FD.minimal a, FD.maximal a with
              | Some c_min, Some c_max, Some a_min, Some a_max when Float.is_finite (Float.pred c_min) && Float.is_finite (Float.succ c_max) ->
                let v1, v2, v3, v4 = (a_min /. Float.pred c_min), (a_max /. Float.pred c_min), (a_min /. Float.succ c_max), (a_max /. Float.succ c_max) in
                let l = Float.min (Float.min v1 v2) (Float.min v3 v4) in
                let h =  Float.max (Float.max v1 v2) (Float.max v3 v4) in
                FD.of_interval (FD.get_fkind c) (l, h)
              | _ -> b) in
          meet_bin a' b'
        | Eq | Ne as op ->
          let both x = x, x in
          (match op, ID.to_bool (FD.to_int IBool c) with
          | Eq, Some true
          | Ne, Some false -> both (FD.meet a b) (* def. equal: if they compare equal, both values must be from the meet *)
          | Eq, Some false
          | Ne, Some true -> (* def. unequal *)
            (* M.debug ~category:Analyzer "Can't use unequal information about float value in expression \"%a\"." d_plainexp exp; *)
            a, b (* TODO: no meet_bin? *)
          | _, _ -> a, b
          )
        | Lt | Le | Ge | Gt as op ->
          (match FD.minimal a, FD.maximal a, FD.minimal b, FD.maximal b with
          | Some l1, Some u1, Some l2, Some u2 ->
            (match op, ID.to_bool (FD.to_int IBool c) with
              | Le, Some true
              | Gt, Some false -> meet_bin (FD.ending (FD.get_fkind a) u2) (FD.starting (FD.get_fkind b) l1)
              | Ge, Some true
              | Lt, Some false -> meet_bin (FD.starting (FD.get_fkind a) l2) (FD.ending (FD.get_fkind b) u1)
              | Lt, Some true
              | Ge, Some false -> meet_bin (FD.ending_before (FD.get_fkind a) u2) (FD.starting_after (FD.get_fkind b) l1)
              | Gt, Some true
              | Le, Some false -> meet_bin (FD.starting_after (FD.get_fkind a) l2) (FD.ending_before (FD.get_fkind b) u1)
              | _, _ -> a, b)
          | _ -> a, b)
        | op ->
          if M.tracing then M.tracel "inv" "Unhandled operator %a\n" d_binop op;
          a, b
      with FloatDomain.ArithmeticOnFloatBot _ -> raise Analyses.Deadcode
    in
    let eval e st = eval_rv a gs st e in
    let eval_bool e st = match eval e st with `Int i -> ID.to_bool i | _ -> None in
    let rec inv_exp c_typed exp (st:D.t): D.t =
      (* trying to improve variables in an expression so it is bottom means dead code *)
      if VD.is_bot_value c_typed then raise Analyses.Deadcode;
      match exp, c_typed with
      | UnOp (LNot, e, _), `Int c ->
        let ikind = Cilfacade.get_ikind_exp e in
        let c' =
          match ID.to_bool (unop_ID LNot c) with
          | Some true ->
            (* i.e. e should evaluate to [1,1] *)
            (* LNot x is 0 for any x != 0 *)
            ID.of_excl_list ikind [BI.zero]
          | Some false -> ID.of_bool ikind false
          | _ -> ID.top_of ikind
        in
        inv_exp (`Int c') e st
      | UnOp (Neg, e, _), `Float c -> inv_exp (`Float (unop_FD Neg c)) e st
      | UnOp ((BNot|Neg) as op, e, _), `Int c -> inv_exp (`Int (unop_ID op c)) e st
      (* no equivalent for `Float, as VD.is_safe_cast fails for all float types anyways *)
      | BinOp(op, CastE (t1, c1), CastE (t2, c2), t), `Int c when (op = Eq || op = Ne) && typeSig (Cilfacade.typeOf c1) = typeSig (Cilfacade.typeOf c2) && VD.is_safe_cast t1 (Cilfacade.typeOf c1) && VD.is_safe_cast t2 (Cilfacade.typeOf c2) ->
        inv_exp (`Int c) (BinOp (op, c1, c2, t)) st
      | (BinOp (op, e1, e2, _) as e, `Float _)
      | (BinOp (op, e1, e2, _) as e, `Int _) ->
        let invert_binary_op c pretty c_int c_float =
          if M.tracing then M.tracel "inv" "binop %a with %a %a %a == %a\n" d_exp e VD.pretty (eval e1 st) d_binop op VD.pretty (eval e2 st) pretty c;
          (match eval e1 st, eval e2 st with
          | `Int a, `Int b ->
            let ikind = Cilfacade.get_ikind_exp e1 in (* both operands have the same type (except for Shiftlt, Shiftrt)! *)
            let a', b' = inv_bin_int (a, b) ikind (c_int ikind) op in
            if M.tracing then M.tracel "inv" "binop: %a, c: %a, a': %a, b': %a\n" d_exp e ID.pretty (c_int ikind) ID.pretty a' ID.pretty b';
            let st' = inv_exp (`Int a') e1 st in
            let st'' = inv_exp (`Int b') e2 st' in
            st''
          | `Float a, `Float b ->
            let fkind = Cilfacade.get_fkind_exp e1 in (* both operands have the same type *)
            let a', b' = inv_bin_float (a, b) (c_float fkind) op in
            if M.tracing then M.tracel "inv" "binop: %a, c: %a, a': %a, b': %a\n" d_exp e FD.pretty (c_float fkind) FD.pretty a' FD.pretty b';
            let st' = inv_exp (`Float a') e1 st in
            let st'' = inv_exp (`Float b') e2 st' in
            st''
          (* Mixed `Float and `Int cases should never happen, as there are no binary operators with one float and one int parameter ?!*)
          | `Int _, `Float _ | `Float _, `Int _ -> failwith "ill-typed program";
            (* | `Address a, `Address b -> ... *)
          | a1, a2 -> fallback ("binop: got abstract values that are not `Int: " ^ sprint VD.pretty a1 ^ " and " ^ sprint VD.pretty a2) st)
          (* use closures to avoid unused casts *)
        in (match c_typed with
            | `Int c -> invert_binary_op c ID.pretty (fun ik -> ID.cast_to ik c) (fun fk -> FD.of_int fk c)
            | `Float c -> invert_binary_op c FD.pretty (fun ik -> FD.to_int ik c) (fun fk -> FD.cast_to fk c)
            | _ -> failwith "unreachable")
      | Lval x, `Int _(* meet x with c *)
      | Lval x, `Float _ -> (* meet x with c *)
        let update_lval c x c' pretty = refine_lv ctx a gs st c x c' pretty exp in
        let t = Cil.unrollType (Cilfacade.typeOfLval x) in  (* unroll type to deal with TNamed *)
        (match c_typed with
        | `Int c -> update_lval c x (match t with
            | TPtr _ -> `Address (AD.of_int (module ID) c)
            | TInt (ik, _)
            | TEnum ({ekind = ik; _}, _) -> `Int (ID.cast_to ik c)
            | TFloat (fk, _) -> `Float (FD.of_int fk c)
            | _ -> `Int c) ID.pretty
        | `Float c -> update_lval c x (match t with
            (* | TPtr _ -> ..., pointer conversion from/to float is not supported *)
            | TInt (ik, _) -> `Int (FD.to_int ik c)
            (* this is theoretically possible and should be handled correctly, however i can't imagine an actual piece of c code producing this?! *)
            | TEnum ({ekind = ik; _}, _) -> `Int (FD.to_int ik c)
            | TFloat (fk, _) -> `Float (FD.cast_to fk c)
            | _ -> `Float c) FD.pretty
        | _ -> failwith "unreachable")
      | Const _ , _ -> st (* nothing to do *)
      | CastE ((TFloat (_, _)), e), `Float c ->
        (match Cilfacade.typeOf e, FD.get_fkind c with
        | TFloat (FLongDouble as fk, _), FFloat
        | TFloat (FDouble as fk, _), FFloat
        | TFloat (FLongDouble as fk, _), FDouble
        | TFloat (fk, _), FLongDouble
        | TFloat (FDouble as fk, _), FDouble
        | TFloat (FFloat as fk, _), FFloat -> inv_exp (`Float (FD.cast_to fk c)) e st
        | _ -> fallback ("CastE: incompatible types") st)
      | CastE ((TInt (ik, _)) as t, e), `Int c
      | CastE ((TEnum ({ekind = ik; _ }, _)) as t, e), `Int c -> (* Can only meet the t part of an Lval in e with c (unless we meet with all overflow possibilities)! Since there is no good way to do this, we only continue if e has no values outside of t. *)
        (match eval e st with
        | `Int i ->
          if ID.leq i (ID.cast_to ik i) then
            match Cilfacade.typeOf e with
            | TInt(ik_e, _)
            | TEnum ({ekind = ik_e; _ }, _) ->
              (* let c' = ID.cast_to ik_e c in *)
              let c' = ID.cast_to ik_e (ID.meet c (ID.cast_to ik (ID.top_of ik_e))) in (* TODO: cast without overflow, is this right for normal invariant? *)
              if M.tracing then M.tracel "inv" "cast: %a from %a to %a: i = %a; cast c = %a to %a = %a\n" d_exp e d_ikind ik_e d_ikind ik ID.pretty i ID.pretty c d_ikind ik_e ID.pretty c';
              inv_exp (`Int c') e st
            | x -> fallback ("CastE: e did evaluate to `Int, but the type did not match" ^ sprint d_type t) st
          else
            fallback ("CastE: " ^ sprint d_plainexp e ^ " evaluates to " ^ sprint ID.pretty i ^ " which is bigger than the type it is cast to which is " ^ sprint d_type t) st
        | v -> fallback ("CastE: e did not evaluate to `Int, but " ^ sprint VD.pretty v) st)
      | e, _ -> fallback (sprint d_plainexp e ^ " not implemented") st
    in
    if eval_bool exp st = Some (not tv) then raise Analyses.Deadcode (* we already know that the branch is dead *)
    else
      (* C11 6.5.13, 6.5.14, 6.5.3.3: LAnd, LOr and LNot also return 0 or 1 *)
      let is_cmp = function
        | UnOp (LNot, _, _)
        | BinOp ((Lt | Gt | Le | Ge | Eq | Ne | LAnd | LOr), _, _, _) -> true
        | _ -> false
      in
      try
        let ik = Cilfacade.get_ikind_exp exp in
        let itv = if not tv || is_cmp exp then (* false is 0, but true can be anything that is not 0, except for comparisons which yield 1 *)
            ID.of_bool ik tv (* this will give 1 for true which is only ok for comparisons *)
          else
            ID.of_excl_list ik [BI.zero] (* Lvals, Casts, arithmetic operations etc. should work with true = non_zero *)
        in
        inv_exp (`Int itv) exp st
      with Invalid_argument _ ->
        let fk = Cilfacade.get_fkind_exp exp in
        let ftv = if not tv then (* false is 0, but true can be anything that is not 0, except for comparisons which yield 1 *)
            FD.of_const fk 0.
          else
            FD.top_of fk
        in
        inv_exp (`Float ftv) exp st
end