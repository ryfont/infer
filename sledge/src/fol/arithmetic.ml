(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(** Arithmetic terms *)

include Arithmetic_intf

module Representation
    (Var : Var_intf.S)
    (Trm : INDETERMINATE with type var := Var.t) =
struct
  module Prod = struct
    include Multiset.Make (Trm) (Int)

    let t_of_sexp = t_of_sexp Trm.t_of_sexp
  end

  module Mono = struct
    type t = Prod.t [@@deriving compare, equal, sexp]

    let num_den m = Prod.partition m ~f:(fun _ i -> i >= 0)

    let ppx pp_trm ppf power_product =
      let pp_factor ppf (indet, exponent) =
        if exponent = 1 then pp_trm ppf indet
        else Format.fprintf ppf "%a^%i" pp_trm indet exponent
      in
      let pp_num ppf num =
        if Prod.is_empty num then Trace.pp_styled `Magenta "1" ppf
        else Prod.pp "@ @<2>× " pp_factor ppf num
      in
      let pp_den ppf den =
        if not (Prod.is_empty den) then
          Format.fprintf ppf "@ / %a"
            (Prod.pp "@ / " pp_factor)
            (Prod.map_counts ~f:Int.neg den)
      in
      let num, den = num_den power_product in
      if Prod.is_singleton num && Prod.is_empty den then
        Format.fprintf ppf "@[<2>%a@]" pp_num num
      else Format.fprintf ppf "@[<2>(%a%a)@]" pp_num num pp_den den

    let pp = ppx Trm.pp

    (** [one] is the empty product Πᵢ₌₁⁰ xᵢ^pᵢ *)
    let one = Prod.empty

    let equal_one = Prod.is_empty

    (** [of_ x₁ p₁] is the singleton product Πᵢ₌₁¹ x₁^p₁ *)
    let of_ x p = Prod.of_ x p

    (** [pow (Πᵢ₌₁ⁿ xᵢ^pᵢ) p] is Πᵢ₌₁ⁿ xᵢ^(pᵢ×p) *)
    let pow mono = function
      | 0 -> Prod.empty
      | 1 -> mono
      | power -> Prod.map_counts ~f:(Int.mul power) mono

    let mul x y = Prod.union x y

    (** [get_trm m] is [Some x] iff [equal m (of_ x 1)] *)
    let get_trm mono =
      match Prod.only_elt mono with Some (trm, 1) -> Some trm | _ -> None

    (* traverse *)

    let trms mono =
      Iter.from_iter (fun f -> Prod.iter mono ~f:(fun trm _ -> f trm))

    (* query *)

    let vars p = Iter.flat_map ~f:Trm.vars (trms p)
    let fv p = Var.Set.of_iter (vars p)
  end

  module Sum = struct
    include Multiset.Make (Mono) (Q)

    let t_of_sexp = t_of_sexp Mono.t_of_sexp
  end

  module Poly = Sum
  include Poly

  module Make (Embed : EMBEDDING with type trm := Trm.t and type t := t) =
  struct
    include Poly

    let ppx pp_trm ppf poly =
      if Sum.is_empty poly then Trace.pp_styled `Magenta "0" ppf
      else
        let pp_coeff_mono ppf (m, c) =
          if Mono.equal_one m then Trace.pp_styled `Magenta "%a" ppf Q.pp c
          else if Q.equal Q.one c then
            Format.fprintf ppf "%a" (Mono.ppx pp_trm) m
          else Format.fprintf ppf "%a@<1>×%a" Q.pp c (Mono.ppx pp_trm) m
        in
        if Sum.is_singleton poly then
          Format.fprintf ppf "@[<2>%a@]" (Sum.pp "@ + " pp_coeff_mono) poly
        else
          Format.fprintf ppf "@[<2>(%a)@]"
            (Sum.pp "@ + " pp_coeff_mono)
            poly

    let pp = ppx Trm.pp

    let mono_invariant mono =
      let@ () = Invariant.invariant [%here] mono [%sexp_of: Mono.t] in
      Prod.iter mono ~f:(fun base power ->
          (* powers are non-zero *)
          assert (not (Int.equal Int.zero power)) ;
          match Embed.get_arith base with
          | None -> ()
          | Some poly -> (
            match Sum.classify poly with
            | `Many -> ()
            | `Zero | `One _ ->
                (* polynomial factors are not constant or singleton, which
                   should have been flattened into the parent monomial *)
                assert false ) ) ;
      match Mono.get_trm mono with
      | None -> ()
      | Some trm -> (
        match Embed.get_arith trm with
        | None -> ()
        | Some _ ->
            (* singleton monomials are not polynomials, which should have
               been flattened into the parent polynomial *)
            assert false )

    let invariant poly =
      let@ () = Invariant.invariant [%here] poly [%sexp_of: t] in
      Sum.iter poly ~f:(fun mono coeff ->
          (* coefficients are non-zero *)
          assert (not (Q.equal Q.zero coeff)) ;
          mono_invariant mono )

    (* constants *)

    let const q = Sum.of_ Mono.one q |> check invariant
    let zero = const Q.zero |> check (fun p -> assert (Sum.is_empty p))

    (* core constructors *)

    let neg poly = Sum.map_counts ~f:Q.neg poly |> check invariant
    let add p q = Sum.union p q |> check invariant
    let sub p q = add p (neg q)

    let mulc coeff poly =
      ( if Q.equal Q.one coeff then poly
      else if Q.equal Q.zero coeff then zero
      else Sum.map_counts ~f:(Q.mul coeff) poly )
      |> check invariant

    (* projections and embeddings *)

    type kind = Trm of Trm.t | Const of Q.t | Interpreted | Uninterpreted

    let classify poly =
      match Sum.classify poly with
      | `Zero -> Const Q.zero
      | `One (mono, coeff) -> (
        match Prod.classify mono with
        | `Zero -> Const coeff
        | `One (trm, 1) ->
            if Q.equal Q.one coeff then Trm trm else Interpreted
        | _ -> Uninterpreted )
      | `Many -> Interpreted

    let is_uninterpreted poly =
      match Sum.only_elt poly with
      | Some (mono, _) -> (
        match Prod.classify mono with
        | `Zero -> false
        | `One (_, 1) -> false
        | _ -> true )
      | None -> false

    let get_const poly =
      match Sum.classify poly with
      | `Zero -> Some Q.zero
      | `One (mono, coeff) when Mono.equal_one mono -> Some coeff
      | _ -> None

    let get_mono poly =
      match Sum.only_elt poly with
      | Some (mono, coeff) when Q.equal Q.one coeff -> Some mono
      | _ -> None

    (** Terms of a polynomial: product of a coefficient and a monomial *)
    module CM = struct
      type t = Q.t * Prod.t

      let mul (c1, m1) (c2, m2) = (Q.mul c1 c2, Mono.mul m1 m2)

      (** Monomials [Mono.t] have [trm] indeterminates, which include, via
          [get_arith], polynomials [t] over monomials themselves. To avoid
          redundant representations, singleton polynomials are flattened. *)
      let of_trm : ?power:int -> Trm.t -> t =
       fun ?(power = 1) base ->
        [%trace]
          ~call:(fun {pf} -> pf "@ %a^%i" Trm.pp base power)
          ~retn:(fun {pf} (c, m) -> pf "%a×%a" Q.pp c Mono.pp m)
        @@ fun () ->
        match Embed.get_arith base with
        | Some poly -> (
          match Sum.classify poly with
          (* 0 ^ p₁ ==> 0 × 1 *)
          | `Zero -> (Q.zero, Mono.one)
          (* (Σᵢ₌₁¹ cᵢ × Xᵢ) ^ p₁ ==> cᵢ^p₁ × Πⱼ₌₁¹ Xⱼ^pⱼ *)
          | `One (mono, coeff) -> (Q.pow coeff power, Mono.pow mono power)
          (* (Σᵢ₌₁ⁿ cᵢ × Xᵢ) ^ p₁ ==> 1 × Πⱼ₌₁¹ (Σᵢ₌₁ⁿ cᵢ × Xᵢ)^pⱼ *)
          | `Many -> (Q.one, Mono.of_ base power) )
        (* X₁ ^ p₁ ==> 1 × Πⱼ₌₁¹ Xⱼ^pⱼ *)
        | None -> (Q.one, Mono.of_ base power)

      (** Polynomials [t] have [trm] indeterminates, which, via [get_arith],
          include polynomials themselves. To avoid redundant
          representations, singleton monomials are flattened. Also, constant
          multiplication is not interpreted in [Prod], so constant
          polynomials are multiplied by their coefficients directly. *)
      let to_poly : t -> Poly.t =
       fun (coeff, mono) ->
        [%trace]
          ~call:(fun {pf} -> pf "@ %a×%a" Q.pp coeff Mono.pp mono)
          ~retn:(fun {pf} -> pf "%a" pp)
        @@ fun () ->
        ( match Mono.get_trm mono with
        | Some trm -> (
          match Embed.get_arith trm with
          (* c × (Σᵢ₌₁ⁿ cᵢ × Xᵢ) ==> Σᵢ₌₁ⁿ c×cᵢ × Xᵢ *)
          | Some poly -> mulc coeff poly
          (* c₁ × X₁ ==> Σᵢ₌₁¹ cᵢ × Xᵢ *)
          | None -> Sum.of_ mono coeff )
        (* c₁ × (Πⱼ₌₁ᵐ X₁ⱼ^p₁ⱼ) ==> Σᵢ₌₁¹ cᵢ × (Πⱼ₌₁ᵐ Xᵢⱼ^pᵢⱼ) *)
        | None -> Sum.of_ mono coeff )
        |> check invariant
    end

    (** Embed a monomial into a term, flattening if possible *)
    let trm_of_mono mono =
      match Mono.get_trm mono with
      | Some trm -> trm
      | None -> Embed.to_trm (Sum.of_ mono Q.one)

    (** Embed a term into a polynomial, by projecting a polynomial out of
        the term if possible *)
    let trm trm =
      ( match Embed.get_arith trm with
      | Some poly -> poly
      | None -> Sum.of_ (Mono.of_ trm 1) Q.one )
      |> check (fun poly ->
             assert (equal poly (CM.to_poly (CM.of_trm trm))) )

    (** Project out the term embedded into a polynomial, if possible *)
    let get_trm poly =
      match get_mono poly with
      | Some mono -> Mono.get_trm mono
      | None -> None

    (* constructors over indeterminates *)

    let mul e1 e2 = CM.to_poly (CM.mul (CM.of_trm e1) (CM.of_trm e2))

    let div n d =
      CM.to_poly (CM.mul (CM.of_trm n) (CM.of_trm d ~power:(-1)))

    let pow base power = CM.to_poly (CM.of_trm base ~power)

    (* transform *)

    let split_const poly =
      match Sum.find_and_remove Mono.one poly with
      | Some (c, p_c) -> (p_c, c)
      | None -> (poly, Q.zero)

    let partition_sign poly =
      Sum.partition_map poly ~f:(fun _ coeff ->
          if Q.sign coeff >= 0 then Left coeff else Right (Q.neg coeff) )

    (* traverse *)

    let monos poly =
      Iter.from_iter (fun f ->
          Sum.iter poly ~f:(fun mono _ ->
              if not (Mono.equal_one mono) then f mono ) )

    let trms poly =
      match get_mono poly with
      | Some mono -> Mono.trms mono
      | None -> Iter.map ~f:trm_of_mono (monos poly)

    (* map over [trms] *)
    let map poly ~f =
      [%trace]
        ~call:(fun {pf} -> pf "@ %a" pp poly)
        ~retn:(fun {pf} -> pf "%a" pp)
      @@ fun () ->
      ( match get_mono poly with
      | Some mono ->
          let mono', (coeff, mono_delta) =
            Prod.fold mono
              (mono, (Q.one, Mono.one))
              ~f:(fun base power (mono', delta) ->
                let base' = f base in
                if base' == base then (mono', delta)
                else
                  ( Prod.remove base mono'
                  , CM.mul delta (CM.of_trm ~power base') ) )
          in
          if mono' == mono then poly
          else CM.to_poly (coeff, Mono.mul mono' mono_delta)
      | None ->
          let poly', delta =
            Sum.fold poly (poly, Sum.empty)
              ~f:(fun mono coeff (poly', delta) ->
                if Mono.equal_one mono then (poly', delta)
                else
                  let e = trm_of_mono mono in
                  let e' = f e in
                  if e == e' then (poly', delta)
                  else
                    ( Sum.remove mono poly'
                    , Sum.union delta (mulc coeff (trm e')) ) )
          in
          Sum.union poly' delta )
      |> check invariant

    (* query *)

    let vars p = Iter.flat_map ~f:Trm.vars (trms p)

    (* solve *)

    let exists_fv_in vs poly =
      Iter.exists ~f:(fun v -> Var.Set.mem v vs) (vars poly)

    (** [solve_for_mono r c m p] solves [0 = r + (c×m) + p] as [m = q]
        ([Some (m, q)]) such that [r + (c×m) + p = m - q] *)
    let solve_for_mono rejected_poly coeff mono poly =
      [%trace]
        ~call:(fun {pf} ->
          pf "@ 0 = %a + (%a×%a) + %a" pp rejected_poly Q.pp coeff Mono.pp
            mono pp poly )
        ~retn:(fun {pf} s ->
          pf "%a"
            (Option.pp "%a" (fun fs (v, q) ->
                 Format.fprintf fs "%a ↦ %a" pp v pp q ))
            s )
      @@ fun () ->
      if Mono.equal_one mono || exists_fv_in (Mono.fv mono) poly then None
      else
        Some
          ( Sum.of_ mono Q.one
          , mulc (Q.inv (Q.neg coeff)) (Sum.union rejected_poly poly) )

    (** [solve_poly r p] solves [0 = r + p] as [m = q] ([Some (m, q)]) such
        that [r + p = m - q] *)
    let rec solve_poly rejected poly =
      [%trace]
        ~call:(fun {pf} -> pf "@ 0 = (%a) + (%a)" pp rejected pp poly)
        ~retn:(fun {pf} s ->
          pf "%a"
            (Option.pp "%a" (fun fs (v, q) ->
                 Format.fprintf fs "%a ↦ %a" pp v pp q ))
            s )
      @@ fun () ->
      let* mono, coeff, poly = Sum.pop_min_elt poly in
      match solve_for_mono rejected coeff mono poly with
      | Some _ as soln -> soln
      | None -> solve_poly (Sum.add mono coeff rejected) poly

    (* solve [0 = e] *)
    let solve_zero_eq ?for_ e =
      [%trace]
        ~call:(fun {pf} ->
          pf "@ 0 = %a%a" Trm.pp e (Option.pp " for %a" Trm.pp) for_ )
        ~retn:(fun {pf} s ->
          pf "%a"
            (Option.pp "%a" (fun fs (c, r) ->
                 Format.fprintf fs "%a ↦ %a" pp c pp r ))
            s ;
          match (for_, s) with
          | Some f, Some (c, _) -> assert (equal (trm f) c)
          | _ -> () )
      @@ fun () ->
      let a = trm e in
      match for_ with
      | None -> solve_poly Sum.empty a
      | Some for_ -> (
          let for_poly = trm for_ in
          match get_mono for_poly with
          | Some m ->
              let* c, p = Sum.find_and_remove m a in
              solve_for_mono Sum.empty c m p
          | _ -> None )
  end
  [@@inline]
end
[@@inline]
