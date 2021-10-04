open Core
open Signature_lib
open Mina_base
open Mina_state
open Snark_params
module Global_slot = Mina_numbers.Global_slot
open Currency
open Pickles_types
module Impl = Pickles.Impls.Step

let top_hash_logging_enabled = ref false

let to_preunion (t : Transaction.t) =
  match t with
  | Command (Signed_command x) ->
      `Transaction (Transaction.Command x)
  | Fee_transfer x ->
      `Transaction (Fee_transfer x)
  | Coinbase x ->
      `Transaction (Coinbase x)
  | Command (Parties x) ->
      `Parties x

let with_top_hash_logging f =
  let old = !top_hash_logging_enabled in
  top_hash_logging_enabled := true ;
  try
    let ret = f () in
    top_hash_logging_enabled := old ;
    ret
  with err ->
    top_hash_logging_enabled := old ;
    raise err

module Proof_type = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = [ `Base | `Merge ]
      [@@deriving compare, equal, hash, sexp, yojson]

      let to_latest = Fn.id
    end
  end]
end

module Pending_coinbase_stack_state = struct
  module Init_stack = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = Base of Pending_coinbase.Stack_versioned.Stable.V1.t | Merge
        [@@deriving sexp, hash, compare, equal, yojson]

        let to_latest = Fn.id
      end
    end]
  end

  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type 'pending_coinbase t =
          { source : 'pending_coinbase; target : 'pending_coinbase }
        [@@deriving sexp, hash, compare, equal, fields, yojson, hlist]

        let to_latest pending_coinbase { source; target } =
          { source = pending_coinbase source; target = pending_coinbase target }
      end
    end]

    let typ pending_coinbase =
      Tick.Typ.of_hlistable
        [ pending_coinbase; pending_coinbase ]
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist
  end

  type 'pending_coinbase poly = 'pending_coinbase Poly.t =
    { source : 'pending_coinbase; target : 'pending_coinbase }
  [@@deriving sexp, hash, compare, equal, fields, yojson]

  (* State of the coinbase stack for the current transaction snark *)
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Pending_coinbase.Stack_versioned.Stable.V1.t Poly.Stable.V1.t
      [@@deriving sexp, hash, compare, equal, yojson]

      let to_latest = Fn.id
    end
  end]

  type var = Pending_coinbase.Stack.var Poly.t

  let typ = Poly.typ Pending_coinbase.Stack.typ

  let to_input ({ source; target } : t) =
    Random_oracle.Input.append
      (Pending_coinbase.Stack.to_input source)
      (Pending_coinbase.Stack.to_input target)

  let var_to_input ({ source; target } : var) =
    Random_oracle.Input.append
      (Pending_coinbase.Stack.var_to_input source)
      (Pending_coinbase.Stack.var_to_input target)

  include Hashable.Make_binable (Stable.Latest)
  include Comparable.Make (Stable.Latest)
end

module Statement = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V2 = struct
        type ( 'ledger_hash
             , 'amount
             , 'pending_coinbase
             , 'fee_excess
             , 'token_id
             , 'sok_digest
             , 'local_state )
             t =
          { source :
              ( 'ledger_hash
              , 'pending_coinbase
              , 'token_id
              , 'local_state )
              Registers.Stable.V1.t
          ; target :
              ( 'ledger_hash
              , 'pending_coinbase
              , 'token_id
              , 'local_state )
              Registers.Stable.V1.t
          ; supply_increase : 'amount
          ; fee_excess : 'fee_excess
          ; sok_digest : 'sok_digest
          }
        [@@deriving compare, equal, hash, sexp, yojson, hlist]
      end

      module V1 = struct
        type ( 'ledger_hash
             , 'amount
             , 'pending_coinbase
             , 'fee_excess
             , 'token_id
             , 'sok_digest )
             t =
          { source : 'ledger_hash
          ; target : 'ledger_hash
          ; supply_increase : 'amount
          ; pending_coinbase_stack_state : 'pending_coinbase
          ; fee_excess : 'fee_excess
          ; next_available_token_before : 'token_id
          ; next_available_token_after : 'token_id
          ; sok_digest : 'sok_digest
          }
        [@@deriving compare, equal, hash, sexp, yojson, hlist]
      end
    end]

    let to_latest (t : _ Stable.V1.t) : _ Stable.V2.t =
      { supply_increase = t.supply_increase
      ; fee_excess = t.fee_excess
      ; sok_digest = t.sok_digest
      ; source =
          { ledger = t.source
          ; pending_coinbase_stack =
              t.pending_coinbase_stack_state.Pending_coinbase_stack_state.source
          ; next_available_token = t.next_available_token_before
          ; local_state = Local_state.empty
          }
      ; target =
          { ledger = t.target
          ; pending_coinbase_stack = t.pending_coinbase_stack_state.target
          ; next_available_token = t.next_available_token_after
          ; local_state = Local_state.empty
          }
      }

    let typ ledger_hash amount pending_coinbase fee_excess token_id sok_digest
        local_state_typ =
      let registers =
        let open Registers in
        Tick.Typ.of_hlistable
          [ ledger_hash; pending_coinbase; token_id; local_state_typ ]
          ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
          ~value_of_hlist:of_hlist
      in
      Tick.Typ.of_hlistable
        [ registers; registers; amount; fee_excess; sok_digest ]
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist
  end

  type ( 'ledger_hash
       , 'amount
       , 'pending_coinbase
       , 'fee_excess
       , 'token_id
       , 'sok_digest
       , 'local_state )
       poly =
        ( 'ledger_hash
        , 'amount
        , 'pending_coinbase
        , 'fee_excess
        , 'token_id
        , 'sok_digest
        , 'local_state )
        Poly.t =
    { source :
        ('ledger_hash, 'pending_coinbase, 'token_id, 'local_state) Registers.t
    ; target :
        ('ledger_hash, 'pending_coinbase, 'token_id, 'local_state) Registers.t
    ; supply_increase : 'amount
    ; fee_excess : 'fee_excess
    ; sok_digest : 'sok_digest
    }
  [@@deriving compare, equal, hash, sexp, yojson]

  [%%versioned
  module Stable = struct
    module V2 = struct
      type t =
        ( Frozen_ledger_hash.Stable.V1.t
        , Currency.Amount.Stable.V1.t
        , Pending_coinbase.Stack_versioned.Stable.V1.t
        , Fee_excess.Stable.V1.t
        , Token_id.Stable.V1.t
        , unit
        , Local_state.Stable.V1.t )
        Poly.Stable.V2.t
      [@@deriving compare, equal, hash, sexp, yojson]

      let to_latest = Fn.id
    end

    module V1 = struct
      type t =
        ( Frozen_ledger_hash.Stable.V1.t
        , Currency.Amount.Stable.V1.t
        , Pending_coinbase_stack_state.Stable.V1.t
        , Fee_excess.Stable.V1.t
        , Token_id.Stable.V1.t
        , unit )
        Poly.Stable.V1.t
      [@@deriving compare, equal, hash, sexp, yojson]

      let to_latest : t -> V2.t = Poly.to_latest
    end
  end]

  module With_sok = struct
    [%%versioned
    module Stable = struct
      module V2 = struct
        type t =
          ( Frozen_ledger_hash.Stable.V1.t
          , Currency.Amount.Stable.V1.t
          , Pending_coinbase.Stack_versioned.Stable.V1.t
          , Fee_excess.Stable.V1.t
          , Token_id.Stable.V1.t
          , Sok_message.Digest.Stable.V1.t
          , Local_state.Stable.V1.t )
          Poly.Stable.V2.t
        [@@deriving compare, equal, hash, sexp, yojson]

        let to_latest = Fn.id
      end

      module V1 = struct
        type t =
          ( Frozen_ledger_hash.Stable.V1.t
          , Currency.Amount.Stable.V1.t
          , Pending_coinbase_stack_state.Stable.V1.t
          , Fee_excess.Stable.V1.t
          , Token_id.Stable.V1.t
          , Sok_message.Digest.Stable.V1.t )
          Poly.Stable.V1.t
        [@@deriving compare, equal, hash, sexp, yojson]

        let to_latest = Poly.to_latest
      end
    end]

    type var =
      ( Frozen_ledger_hash.var
      , Currency.Amount.var
      , Pending_coinbase.Stack.var
      , Fee_excess.var
      , Token_id.var
      , Sok_message.Digest.Checked.t
      , Local_state.Checked.t )
      Poly.t

    let typ : (var, t) Tick.Typ.t =
      Poly.typ Frozen_ledger_hash.typ Currency.Amount.typ
        Pending_coinbase.Stack.typ Fee_excess.typ Token_id.typ
        Sok_message.Digest.typ Local_state.typ

    let to_input { source; target; supply_increase; fee_excess; sok_digest } =
      let input =
        Array.reduce_exn ~f:Random_oracle.Input.append
          [| Sok_message.Digest.to_input sok_digest
           ; Registers.to_input source
           ; Registers.to_input target
           ; Amount.to_input supply_increase
           ; Fee_excess.to_input fee_excess
          |]
      in
      if !top_hash_logging_enabled then
        Format.eprintf
          !"Generating unchecked top hash from:@.%{sexp: (Tick.Field.t, bool) \
            Random_oracle.Input.t}@."
          input ;
      input

    let to_field_elements t = Random_oracle.pack_input (to_input t)

    module Checked = struct
      type t = var

      let to_input { source; target; supply_increase; fee_excess; sok_digest } =
        let open Tick in
        let open Checked.Let_syntax in
        let%bind fee_excess = Fee_excess.to_input_checked fee_excess in
        let%bind source =
          make_checked (fun () -> Registers.Checked.to_input source)
        and target =
          make_checked (fun () -> Registers.Checked.to_input target)
        in
        let input =
          Array.reduce_exn ~f:Random_oracle.Input.append
            [| Sok_message.Digest.Checked.to_input sok_digest
             ; source
             ; target
             ; Amount.var_to_input supply_increase
             ; fee_excess
            |]
        in
        let%map () =
          as_prover
            As_prover.(
              if !top_hash_logging_enabled then
                let%bind field_elements =
                  read
                    (Typ.list ~length:0 Field.typ)
                    (Array.to_list input.field_elements)
                in
                let%map bitstrings =
                  read
                    (Typ.list ~length:0 (Typ.list ~length:0 Boolean.typ))
                    (Array.to_list input.bitstrings)
                in
                Format.eprintf
                  !"Generating checked top hash from:@.%{sexp: (Field.t, bool) \
                    Random_oracle.Input.t}@."
                  { Random_oracle.Input.field_elements =
                      Array.of_list field_elements
                  ; bitstrings = Array.of_list bitstrings
                  }
              else return ())
        in
        input

      let to_field_elements t =
        let open Tick.Checked.Let_syntax in
        Tick.Run.run_checked (to_input t >>| Random_oracle.Checked.pack_input)
    end
  end

  let option lab =
    Option.value_map ~default:(Or_error.error_string lab) ~f:(fun x -> Ok x)

  let merge (s1 : _ Poly.t) (s2 : _ Poly.t) =
    let open Or_error.Let_syntax in
    let registers_check_equal (t1 : _ Registers.t) (t2 : _ Registers.t) =
      let check' k f =
        let x1 = Field.get f t1 and x2 = Field.get f t2 in
        k x1 x2
      in
      let module S = struct
        module type S = sig
          type t [@@deriving eq, sexp_of]
        end
      end in
      let check (type t) (module T : S.S with type t = t) f =
        let open T in
        check'
          (fun x1 x2 ->
            if equal x1 x2 then return ()
            else
              Or_error.errorf
                !"%s is inconsistent between transitions (%{sexp: t} vs \
                  %{sexp: t})"
                (Field.name f) x1 x2)
          f
      in
      Registers.Fields.to_list
        ~ledger:(check (module Ledger_hash))
        ~pending_coinbase_stack:(fun _ ->
          let `Needs_some_work_for_snapps_on_mainnet =
            Mina_base.Util.todo_snapps
          in
          (* This is not checking to match the behavior on compatible. We should actually be checking here, but that
             requires a change in how we compute scan_statement in transaction_snark_scan_statement.ml *)
          Ok ())
        ~next_available_token:(check (module Token_id))
        ~local_state:(check (module Local_state))
      |> Or_error.combine_errors_unit
    in
    let%map fee_excess = Fee_excess.combine s1.fee_excess s2.fee_excess
    and supply_increase =
      Currency.Amount.add s1.supply_increase s2.supply_increase
      |> option "Error adding supply_increase"
    and () = registers_check_equal s1.target s2.source in
    ( { source = s1.source
      ; target = s2.target
      ; fee_excess
      ; supply_increase
      ; sok_digest = ()
      }
      : t )

  include Hashable.Make_binable (Stable.Latest)
  include Comparable.Make (Stable.Latest)

  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let%map source = Registers.gen
    and target = Registers.gen
    and fee_excess = Fee_excess.gen
    and supply_increase = Currency.Amount.gen in
    let source, target =
      let t1, t2 = (source.next_available_token, target.next_available_token) in
      ( { source with next_available_token = Token_id.min t1 t2 }
      , { target with next_available_token = Token_id.max t1 t2 } )
    in
    ({ source; target; fee_excess; supply_increase; sok_digest = () } : t)
end

module Proof = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Pickles.Proof.Branching_2.Stable.V1.t
      [@@deriving
        version { asserted }, yojson, bin_io, compare, equal, sexp, hash]

      let to_latest = Fn.id
    end
  end]
end

[%%versioned
module Stable = struct
  module V2 = struct
    type t =
      { statement : Statement.With_sok.Stable.V2.t; proof : Proof.Stable.V1.t }
    [@@deriving compare, equal, fields, sexp, version, yojson, hash]

    let to_latest = Fn.id
  end

  module V1 = struct
    type t =
      { statement : Statement.With_sok.Stable.V1.t; proof : Proof.Stable.V1.t }
    [@@deriving compare, equal, fields, sexp, version, yojson, hash]

    let to_latest (t : t) : Latest.t =
      { statement = Statement.With_sok.Stable.V1.to_latest t.statement
      ; proof = t.proof
      }
  end
end]

let proof t = t.proof

let statement t = { t.statement with sok_digest = () }

let sok_digest t = t.statement.sok_digest

let to_yojson = Stable.Latest.to_yojson

let create ~statement ~proof = { statement; proof }

open Tick
open Let_syntax

let chain if_ b ~then_ ~else_ =
  let%bind then_ = then_ and else_ = else_ in
  if_ b ~then_ ~else_

module Parties_segment = struct
  module Spec = struct
    type single =
      { predicate_type : [ `Full | `Nonce_or_accept ]
      ; auth_type : Control.Tag.t
      ; is_start : [ `Yes | `No | `Compute_in_circuit ]
      }

    type t = single list
  end

  module Basic = struct
    module N = Side_loaded_verification_key.Max_branches

    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          | Opt_signed_unsigned
          | Opt_signed_opt_signed
          | Opt_signed
          | Proved
        [@@deriving sexp]

        let to_latest = Fn.id
      end
    end]

    let of_controls = function
      | [ Control.Proof _ ] ->
          Proved
      | [ (Control.Signature _ | Control.None_given) ] ->
          Opt_signed
      | [ Control.(Signature _ | None_given); Control.None_given ] ->
          Opt_signed_unsigned
      | [ Control.(Signature _ | None_given); Control.Signature _ ] ->
          Opt_signed_opt_signed
      | _ ->
          failwith "Parties_segment.Basic.of_controls: Unsupported combination"

    let opt_signed ~is_start : Spec.single =
      { predicate_type = `Nonce_or_accept; auth_type = Signature; is_start }

    let unsigned : Spec.single =
      { predicate_type = `Nonce_or_accept
      ; auth_type = None_given
      ; is_start = `No
      }

    let opt_signed = opt_signed ~is_start:`Compute_in_circuit

    let to_single_list : t -> Spec.single list =
     fun t ->
      match t with
      | Opt_signed_unsigned ->
          [ opt_signed; unsigned ]
      | Opt_signed_opt_signed ->
          [ opt_signed; opt_signed ]
      | Opt_signed ->
          [ opt_signed ]
      | Proved ->
          [ { predicate_type = `Full; auth_type = Proof; is_start = `No } ]

    type (_, _, _, _) t_typed =
      (* Corresponds to payment *)
      | Opt_signed_unsigned : (unit, unit, unit, unit) t_typed
      | Opt_signed_opt_signed : (unit, unit, unit, unit) t_typed
      | Opt_signed : (unit, unit, unit, unit) t_typed
      | Proved
          : ( Snapp_statement.Checked.t * unit
            , Snapp_statement.t * unit
            , Nat.N2.n * unit
            , N.n * unit )
            t_typed

    let spec : type a b c d. (a, b, c, d) t_typed -> Spec.single list =
     fun t ->
      match t with
      | Opt_signed_unsigned ->
          [ opt_signed; unsigned ]
      | Opt_signed_opt_signed ->
          [ opt_signed; opt_signed ]
      | Opt_signed ->
          [ opt_signed ]
      | Proved ->
          [ { predicate_type = `Full; auth_type = Proof; is_start = `No } ]
  end

  module Witness = Transaction_witness.Parties_segment_witness
end

(* Currently, a circuit must have at least 1 of every type of constraint. *)
let dummy_constraints () =
  make_checked
    Impl.(
      fun () ->
        let b = exists Boolean.typ_unchecked ~compute:(fun _ -> true) in
        let g = exists Inner_curve.typ ~compute:(fun _ -> Inner_curve.one) in
        ignore
          ( Pickles.Step_main_inputs.Ops.scale_fast g
              (`Plus_two_to_len [| b; b |])
            : Pickles.Step_main_inputs.Inner_curve.t ) ;
        ignore
          ( Pickles.Pairing_main.Scalar_challenge.endo g (Scalar_challenge [ b ])
            : Field.t * Field.t ))

module Base = struct
  module User_command_failure = struct
    (** The various ways that a user command may fail. These should be computed
        before applying the snark, to ensure that only the base fee is charged
        to the fee-payer if executing the user command will later fail.
    *)
    type 'bool t =
      { predicate_failed : 'bool (* All *)
      ; source_not_present : 'bool (* All *)
      ; receiver_not_present : 'bool (* Delegate, Mint_tokens *)
      ; amount_insufficient_to_create : 'bool (* Payment only *)
      ; token_cannot_create : 'bool (* Payment only, token<>default *)
      ; source_insufficient_balance : 'bool (* Payment only *)
      ; source_minimum_balance_violation : 'bool (* Payment only *)
      ; source_bad_timing : 'bool (* Payment only *)
      ; receiver_exists : 'bool (* Create_account only *)
      ; not_token_owner : 'bool (* Create_account, Mint_tokens *)
      ; token_auth : 'bool (* Create_account *)
      }

    let num_fields = 11

    let to_list
        { predicate_failed
        ; source_not_present
        ; receiver_not_present
        ; amount_insufficient_to_create
        ; token_cannot_create
        ; source_insufficient_balance
        ; source_minimum_balance_violation
        ; source_bad_timing
        ; receiver_exists
        ; not_token_owner
        ; token_auth
        } =
      [ predicate_failed
      ; source_not_present
      ; receiver_not_present
      ; amount_insufficient_to_create
      ; token_cannot_create
      ; source_insufficient_balance
      ; source_minimum_balance_violation
      ; source_bad_timing
      ; receiver_exists
      ; not_token_owner
      ; token_auth
      ]

    let of_list = function
      | [ predicate_failed
        ; source_not_present
        ; receiver_not_present
        ; amount_insufficient_to_create
        ; token_cannot_create
        ; source_insufficient_balance
        ; source_minimum_balance_violation
        ; source_bad_timing
        ; receiver_exists
        ; not_token_owner
        ; token_auth
        ] ->
          { predicate_failed
          ; source_not_present
          ; receiver_not_present
          ; amount_insufficient_to_create
          ; token_cannot_create
          ; source_insufficient_balance
          ; source_minimum_balance_violation
          ; source_bad_timing
          ; receiver_exists
          ; not_token_owner
          ; token_auth
          }
      | _ ->
          failwith
            "Transaction_snark.Base.User_command_failure.to_list: bad length"

    let typ : (Boolean.var t, bool t) Typ.t =
      let open Typ in
      list ~length:num_fields Boolean.typ
      |> transport ~there:to_list ~back:of_list
      |> transport_var ~there:to_list ~back:of_list

    let any t = Boolean.any (to_list t)

    (** Compute which -- if any -- of the failure cases will be hit when
        evaluating the given user command, and indicate whether the fee-payer
        would need to pay the account creation fee if the user command were to
        succeed (irrespective or whether it actually will or not).
    *)
    let compute_unchecked
        ~(constraint_constants : Genesis_constants.Constraint_constants.t)
        ~txn_global_slot ~creating_new_token ~(fee_payer_account : Account.t)
        ~(receiver_account : Account.t) ~(source_account : Account.t)
        ({ payload; signature = _; signer = _ } : Transaction_union.t) =
      match payload.body.tag with
      | Fee_transfer | Coinbase ->
          (* Not user commands, return no failure. *)
          of_list (List.init num_fields ~f:(fun _ -> false))
      | _ -> (
          let fail s =
            failwithf
              "Transaction_snark.Base.User_command_failure.compute_unchecked: \
               %s"
              s ()
          in
          let fee_token = payload.common.fee_token in
          let token = payload.body.token_id in
          let fee_payer =
            Account_id.create payload.common.fee_payer_pk fee_token
          in
          let source = Account_id.create payload.body.source_pk token in
          let receiver = Account_id.create payload.body.receiver_pk token in
          (* This should shadow the logic in [Sparse_ledger]. *)
          let fee_payer_account =
            { fee_payer_account with
              balance =
                Option.value_exn ?here:None ?error:None ?message:None
                @@ Balance.sub_amount fee_payer_account.balance
                     (Amount.of_fee payload.common.fee)
            }
          in
          let predicate_failed, predicate_result =
            if
              Public_key.Compressed.equal payload.common.fee_payer_pk
                payload.body.source_pk
            then (false, true)
            else
              match payload.body.tag with
              | Create_account when creating_new_token ->
                  (* Any account is allowed to create a new token associated
                     with a public key.
                  *)
                  (false, true)
              | Create_account ->
                  (* Predicate failure is deferred here. It will be checked
                     later.
                  *)
                  let predicate_result =
                    (* TODO(#4554): Hook predicate evaluation in here once
                       implemented.
                    *)
                    false
                  in
                  (false, predicate_result)
              | Payment | Stake_delegation | Mint_tokens ->
                  (* TODO(#4554): Hook predicate evaluation in here once
                     implemented.
                  *)
                  (true, false)
              | Fee_transfer | Coinbase ->
                  assert false
          in
          match payload.body.tag with
          | Fee_transfer | Coinbase ->
              assert false
          | Stake_delegation ->
              let receiver_account =
                if Account_id.equal receiver fee_payer then fee_payer_account
                else receiver_account
              in
              let receiver_not_present =
                let id = Account.identifier receiver_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal receiver id then false
                else fail "bad receiver account ID"
              in
              let source_account =
                if Account_id.equal source fee_payer then fee_payer_account
                else source_account
              in
              let source_not_present =
                let id = Account.identifier source_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal source id then false
                else fail "bad source account ID"
              in
              { predicate_failed
              ; source_not_present
              ; receiver_not_present
              ; amount_insufficient_to_create = false
              ; token_cannot_create = false
              ; source_insufficient_balance = false
              ; source_minimum_balance_violation = false
              ; source_bad_timing = false
              ; receiver_exists = false
              ; not_token_owner = false
              ; token_auth = false
              }
          | Payment ->
              let receiver_account =
                if Account_id.equal receiver fee_payer then fee_payer_account
                else receiver_account
              in
              let receiver_needs_creating =
                let id = Account.identifier receiver_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal receiver id then false
                else fail "bad receiver account ID"
              in
              let token_is_default = Token_id.(equal default) token in
              let token_cannot_create =
                receiver_needs_creating && not token_is_default
              in
              let amount_insufficient_to_create =
                let creation_amount =
                  Amount.of_fee constraint_constants.account_creation_fee
                in
                receiver_needs_creating
                && Option.is_none
                     (Amount.sub payload.body.amount creation_amount)
              in
              let fee_payer_is_source = Account_id.equal fee_payer source in
              let source_account =
                if fee_payer_is_source then fee_payer_account
                else source_account
              in
              let source_not_present =
                let id = Account.identifier source_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal source id then false
                else fail "bad source account ID"
              in
              let source_insufficient_balance =
                (* This failure is fatal if fee-payer and source account are
                   the same. This is checked in the transaction pool.
                *)
                (not fee_payer_is_source)
                &&
                if Account_id.equal source receiver then
                  (* The final balance will be [0 - account_creation_fee]. *)
                  receiver_needs_creating
                else
                  Amount.(
                    Balance.to_amount source_account.balance
                    < payload.body.amount)
              in
              let timing_or_error =
                Transaction_logic.validate_timing
                  ~txn_amount:payload.body.amount ~txn_global_slot
                  ~account:source_account
              in
              let source_minimum_balance_violation =
                match timing_or_error with
                | Ok _ ->
                    false
                | Error err ->
                    let open Mina_base in
                    Transaction_status.Failure.equal
                      (Transaction_logic.timing_error_to_user_command_status
                         err)
                      Transaction_status.Failure
                      .Source_minimum_balance_violation
              in
              let source_bad_timing =
                (* This failure is fatal if fee-payer and source account are
                   the same. This is checked in the transaction pool.
                *)
                (not fee_payer_is_source)
                && (not source_insufficient_balance)
                && Or_error.is_error timing_or_error
              in
              { predicate_failed
              ; source_not_present
              ; receiver_not_present = false
              ; amount_insufficient_to_create
              ; token_cannot_create
              ; source_insufficient_balance
              ; source_minimum_balance_violation
              ; source_bad_timing
              ; receiver_exists = false
              ; not_token_owner = false
              ; token_auth = false
              }
          | Create_account ->
              let receiver_account =
                if Account_id.equal receiver fee_payer then fee_payer_account
                else receiver_account
              in
              let receiver_exists =
                let id = Account.identifier receiver_account in
                if Account_id.equal Account_id.empty id then false
                else if Account_id.equal receiver id then true
                else fail "bad receiver account ID"
              in
              let receiver_account =
                { receiver_account with
                  public_key = Account_id.public_key receiver
                ; token_id = Account_id.token_id receiver
                ; token_permissions =
                    ( if receiver_exists then receiver_account.token_permissions
                    else if creating_new_token then
                      Token_permissions.Token_owned
                        { disable_new_accounts = payload.body.token_locked }
                    else
                      Token_permissions.Not_owned
                        { account_disabled = payload.body.token_locked } )
                }
              in
              let source_account =
                if Account_id.equal source fee_payer then fee_payer_account
                else if Account_id.equal source receiver then receiver_account
                else source_account
              in
              let source_not_present =
                let id = Account.identifier source_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal source id then false
                else fail "bad source account ID"
              in
              let token_auth, not_token_owner =
                if Token_id.(equal default) (Account_id.token_id receiver) then
                  (false, false)
                else
                  match source_account.token_permissions with
                  | Token_owned { disable_new_accounts } ->
                      ( not
                          ( Bool.equal payload.body.token_locked
                              disable_new_accounts
                          || predicate_result )
                      , false )
                  | Not_owned { account_disabled } ->
                      (* NOTE: This [token_auth] value doesn't matter, since we
                         know that there will be a [not_token_owner] failure
                         anyway. We choose this value, since it aliases to the
                         check above in the snark representation of accounts,
                         and so simplifies the snark code.
                      *)
                      ( not
                          ( Bool.equal payload.body.token_locked account_disabled
                          || predicate_result )
                      , true )
              in
              let ret =
                { predicate_failed = false
                ; source_not_present
                ; receiver_not_present = false
                ; amount_insufficient_to_create = false
                ; token_cannot_create = false
                ; source_insufficient_balance = false
                ; source_minimum_balance_violation = false
                ; source_bad_timing = false
                ; receiver_exists
                ; not_token_owner
                ; token_auth
                }
              in
              (* Note: This logic is dependent upon all failures above, so we
                 have to calculate it separately here. *)
              if
                (* If we think the source exists *)
                (not source_not_present)
                (* and there is a failure *)
                && List.exists ~f:Fn.id (to_list ret)
                (* and the receiver account did not exist *)
                && (not receiver_exists)
                (* and the source account was the receiver account *)
                && Account_id.equal source receiver
              then
                (* then the receiver account will not be initialized, and so
                   the source (=receiver) account will not be present.
                *)
                { ret with
                  source_not_present = true
                ; not_token_owner =
                    not Token_id.(equal default (Account_id.token_id receiver))
                ; token_auth =
                    not ((not payload.body.token_locked) || predicate_result)
                }
              else ret
          | Mint_tokens ->
              let receiver_account =
                if Account_id.equal receiver fee_payer then fee_payer_account
                else receiver_account
              in
              let receiver_not_present =
                let id = Account.identifier receiver_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal receiver id then false
                else fail "bad receiver account ID"
              in
              let source_not_present =
                let id = Account.identifier source_account in
                if Account_id.equal Account_id.empty id then true
                else if Account_id.equal source id then false
                else fail "bad source account ID"
              in
              let not_token_owner =
                match source_account.token_permissions with
                | Token_owned _ ->
                    false
                | Not_owned _ ->
                    true
              in
              { predicate_failed
              ; source_not_present
              ; receiver_not_present
              ; amount_insufficient_to_create = false
              ; token_cannot_create = false
              ; source_insufficient_balance = false
              ; source_minimum_balance_violation = false
              ; source_bad_timing = false
              ; receiver_exists = false
              ; not_token_owner
              ; token_auth = false
              } )

    let%snarkydef compute_as_prover ~constraint_constants ~txn_global_slot
        ~creating_new_token ~next_available_token (txn : Transaction_union.var)
        =
      let%bind data =
        exists (Typ.Internal.ref ())
          ~compute:
            As_prover.(
              let%bind txn = read Transaction_union.typ txn in
              let fee_token = txn.payload.common.fee_token in
              let token = txn.payload.body.token_id in
              let%map token =
                if Token_id.(equal invalid) token then
                  read Token_id.typ next_available_token
                else return token
              in
              let fee_payer =
                Account_id.create txn.payload.common.fee_payer_pk fee_token
              in
              let source = Account_id.create txn.payload.body.source_pk token in
              let receiver =
                Account_id.create txn.payload.body.receiver_pk token
              in
              (txn, fee_payer, source, receiver))
      in
      let%bind fee_payer_idx =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map _txn, fee_payer, _source, _receiver =
                read (Typ.Internal.ref ()) data
              in
              Ledger_hash.Find_index fee_payer)
      in
      let%bind fee_payer_account =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map fee_payer_idx =
                read (Typ.Internal.ref ()) fee_payer_idx
              in
              Ledger_hash.Get_element fee_payer_idx)
      in
      let%bind source_idx =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map _txn, _fee_payer, source, _receiver =
                read (Typ.Internal.ref ()) data
              in
              Ledger_hash.Find_index source)
      in
      let%bind source_account =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map source_idx = read (Typ.Internal.ref ()) source_idx in
              Ledger_hash.Get_element source_idx)
      in
      let%bind receiver_idx =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map _txn, _fee_payer, _source, receiver =
                read (Typ.Internal.ref ()) data
              in
              Ledger_hash.Find_index receiver)
      in
      let%bind receiver_account =
        exists (Typ.Internal.ref ())
          ~request:
            As_prover.(
              let%map receiver_idx = read (Typ.Internal.ref ()) receiver_idx in
              Ledger_hash.Get_element receiver_idx)
      in
      exists typ
        ~compute:
          As_prover.(
            let%bind txn, _fee_payer, _source, _receiver =
              read (Typ.Internal.ref ()) data
            in
            let%bind fee_payer_account, _path =
              read (Typ.Internal.ref ()) fee_payer_account
            in
            let%bind source_account, _path =
              read (Typ.Internal.ref ()) source_account
            in
            let%bind receiver_account, _path =
              read (Typ.Internal.ref ()) receiver_account
            in
            let%bind creating_new_token = read Boolean.typ creating_new_token in
            let%map txn_global_slot = read Global_slot.typ txn_global_slot in
            compute_unchecked ~constraint_constants ~txn_global_slot
              ~creating_new_token ~fee_payer_account ~source_account
              ~receiver_account txn)
  end

  let%snarkydef check_signature shifted ~payload ~is_user_command ~signer
      ~signature =
    let%bind input = Transaction_union_payload.Checked.to_input payload in
    let%bind verifies =
      Schnorr.Checked.verifies shifted signature signer input
    in
    Boolean.Assert.any [ Boolean.not is_user_command; verifies ]

  let check_timing ~balance_check ~timed_balance_check ~account ~txn_amount
      ~txn_global_slot =
    (* calculations should track Transaction_logic.validate_timing *)
    let open Account.Poly in
    let open Account.Timing.As_record in
    let { is_timed
        ; initial_minimum_balance
        ; cliff_time
        ; cliff_amount
        ; vesting_period
        ; vesting_increment
        } =
      account.timing
    in
    let int_of_field field =
      Snarky_integer.Integer.constant ~m
        (Bigint.of_field field |> Bigint.to_bignum_bigint)
    in
    let zero_int = int_of_field Field.zero in
    let balance_to_int balance =
      Snarky_integer.Integer.of_bits ~m @@ Balance.var_to_bits balance
    in
    let txn_amount_int =
      Snarky_integer.Integer.of_bits ~m @@ Amount.var_to_bits txn_amount
    in
    let balance_int = balance_to_int account.balance in
    let%bind curr_min_balance =
      Account.Checked.min_balance_at_slot ~global_slot:txn_global_slot
        ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
        ~initial_minimum_balance
    in
    let%bind `Underflow underflow, proposed_balance_int =
      make_checked (fun () ->
          Snarky_integer.Integer.subtract_unpacking_or_zero ~m balance_int
            txn_amount_int)
    in
    (* underflow indicates insufficient balance *)
    let%bind () = balance_check (Boolean.not underflow) in
    let%bind sufficient_timed_balance =
      make_checked (fun () ->
          Snarky_integer.Integer.(gte ~m proposed_balance_int curr_min_balance))
    in
    let%bind () =
      let%bind ok = Boolean.(any [ not is_timed; sufficient_timed_balance ]) in
      timed_balance_check ok
    in
    let%bind is_timed_balance_zero =
      make_checked (fun () ->
          Snarky_integer.Integer.equal ~m curr_min_balance zero_int)
    in
    (* if current min balance is zero, then timing becomes untimed *)
    let%bind is_untimed = Boolean.((not is_timed) ||| is_timed_balance_zero) in
    let%map timing =
      Account.Timing.if_ is_untimed ~then_:Account.Timing.untimed_var
        ~else_:account.timing
    in
    (`Min_balance curr_min_balance, timing)

  let side_loaded =
    Memo.of_comparable
      (module Int)
      (fun i ->
        let open Snapp_statement in
        Pickles.Side_loaded.create ~typ ~name:(sprintf "snapp_%d" i)
          ~max_branching:(module Pickles.Side_loaded.Verification_key.Max_width)
          ~value_to_field_elements:to_field_elements
          ~var_to_field_elements:Checked.to_field_elements)

  let signature_verifies ~shifted ~payload_digest signature pk =
    let%bind pk =
      Public_key.decompress_var pk
      (*           (Account_id.Checked.public_key fee_payer_id) *)
    in
    Schnorr.Checked.verifies shifted signature pk
      (Random_oracle.Input.field payload_digest)

  module Parties_snark = struct
    open Parties_segment
    open Spec

    module Prover_value : sig
      type 'a t

      val get : 'a t -> 'a

      val create : (unit -> 'a) -> 'a t

      val map : 'a t -> f:('a -> 'b) -> 'b t

      val if_ : Boolean.var -> then_:'a t -> else_:'a t -> 'a t
    end = struct
      open Impl

      type 'a t = 'a As_prover.Ref.t

      let get = As_prover.Ref.get

      let create = As_prover.Ref.create

      let if_ b ~then_ ~else_ =
        create (fun () ->
            get (if Impl.As_prover.read Boolean.typ b then then_ else else_))

      let map t ~f = create (fun () -> f (get t))
    end

    module Global_state = struct
      type t =
        { ledger : Ledger_hash.var * Sparse_ledger.t Prover_value.t
        ; fee_excess : Amount.var
        ; protocol_state : Snapp_predicate.Protocol_state.View.Checked.t
        }
    end

    let implied_root account incl =
      let open Impl in
      List.foldi incl ~init:(With_hash.hash account)
        ~f:(fun height acc (b, h) ->
          let l = Field.if_ b ~then_:h ~else_:acc
          and r = Field.if_ b ~then_:acc ~else_:h in
          let acc' = Ledger_hash.merge_var ~height l r in
          acc')

    let apply_body
        ~(constraint_constants : Genesis_constants.Constraint_constants.t) ?tag
        ~txn_global_slot ~(add_check : ?label:string -> Boolean.var -> unit)
        ~check_auth
        ({ body =
             { pk
             ; token_id = _
             ; update =
                 { app_state
                 ; delegate
                 ; verification_key
                 ; permissions
                 ; snapp_uri
                 ; token_symbol
                 ; timing
                 }
             ; delta
             ; events = _ (* This is for the snapp to use, we don't need it. *)
             ; call_data =
                 _ (* This is for the snapp to use, we don't need it. *)
             ; rollup_events
             ; depth = _ (* This is used to build the 'stack of stacks'. *)
             }
         ; predicate
         } :
          Party.Predicated.Checked.t) (a : Account.Checked.Unhashed.t) :
        Account.Checked.Unhashed.t * _ =
      let open Impl in
      let r = ref [] in
      let update_authorized (type a) perm ~is_keep
          ~(updated : [ `Ok of a | `Flagged of a * Boolean.var ]) =
        let speculative_success, `proof_must_verify x = check_auth perm in
        r := lazy Boolean.((not is_keep) &&& x) :: !r ;
        match updated with
        | `Ok res ->
            add_check ~label:__LOC__ Boolean.(speculative_success ||| is_keep) ;
            res
        | `Flagged (res, failed) ->
            add_check ~label:__LOC__
              Boolean.((not failed) &&& speculative_success ||| is_keep) ;
            res
      in
      let proof_must_verify () = Boolean.any (List.map !r ~f:Lazy.force) in
      let ( ! ) = run_checked in
      let is_new =
        !(Public_key.Compressed.Checked.equal a.public_key
            Public_key.Compressed.(var_of_t empty))
      in
      Boolean.Assert.any
        [ is_new; !(Public_key.Compressed.Checked.equal pk a.public_key) ] ;
      let is_receiver = Sgn.Checked.is_pos delta.sgn in
      let timing =
        let open Snapp_basic in
        let new_timing =
          let timing_info = Set_or_keep.Checked.data timing in
          ( { is_timed = Set_or_keep.Checked.is_set timing
            ; initial_minimum_balance = timing_info.initial_minimum_balance
            ; cliff_time = timing_info.cliff_time
            ; cliff_amount = timing_info.cliff_amount
            ; vesting_period = timing_info.vesting_period
            ; vesting_increment = timing_info.vesting_increment
            }
            : Account_timing.var )
        in
        add_check ~label:__LOC__
          Boolean.(is_new || Set_or_keep.Checked.is_keep timing) ;
        !(Account.Timing.if_
            (Set_or_keep.Checked.is_set timing)
            ~then_:new_timing ~else_:a.timing)
      in
      (* Check send/receive permissions *)
      let balance =
        with_label __LOC__ (fun () ->
            update_authorized
              (Permissions.Auth_required.Checked.if_ is_receiver
                 ~then_:a.permissions.receive ~else_:a.permissions.send)
              ~is_keep:!Amount.Signed.(Checked.(equal (constant zero) delta))
              ~updated:
                (let balance, `Overflow failed1 =
                   !(Balance.Checked.add_signed_amount_flagged a.balance delta)
                 in
                 let fee =
                   Amount.Checked.of_fee
                     (Fee.var_of_t constraint_constants.account_creation_fee)
                 in
                 let balance_when_new, `Underflow failed2 =
                   !(Balance.Checked.sub_amount_flagged balance fee)
                 in
                 let res =
                   !(Balance.Checked.if_ is_new ~then_:balance_when_new
                       ~else_:balance)
                 in
                 let failed = Boolean.(failed1 ||| (is_new &&& failed2)) in
                 `Flagged (res, failed)))
      in
      let `Min_balance _, timing =
        !([%with_label "Check snapp timing"]
            (let open Tick in
            let balance_check ok =
              add_check ~label:__LOC__ !(Boolean.any [ ok; is_receiver ]) ;
              return ()
            in
            let timed_balance_check ok =
              add_check ~label:__LOC__ !(Boolean.any [ ok; is_receiver ]) ;
              return ()
            in
            (* NB: We perform the check here with the final balance and a zero
               amount. This allows this to serve dual purposes:
               * if the balance has decreased, this checks that it isn't below
                 the minimum;
               * if the account is new and this party has set its timing info,
                 this checks that the timing is valid.
               The balance and txn_amount are used only to find the resulting
               balance, so using the result directly is equivalent.
            *)
            check_timing ~balance_check ~timed_balance_check
              ~account:{ a with timing; balance }
              ~txn_amount:Amount.(var_of_t zero)
              ~txn_global_slot))
      in
      let open Snapp_basic in
      let snapp : Snapp_account.Checked.t =
        let keeping_app_state =
          Boolean.all
            (List.map (Vector.to_list app_state) ~f:Set_or_keep.Checked.is_keep)
        in
        let changing_app_state =
          Boolean.all
            (List.map (Vector.to_list app_state) ~f:Set_or_keep.Checked.is_set)
        in
        let proved_state =
          Boolean.if_ keeping_app_state ~then_:a.snapp.proved_state
            ~else_:
              ( if Option.is_none tag then (* No proof *)
                Boolean.false_
              else
                (* Has a proof, set proved_state if entire state was set *)
                Boolean.if_ changing_app_state ~then_:Boolean.true_
                  ~else_:a.snapp.proved_state )
        in
        let app_state =
          with_label __LOC__ (fun () ->
              update_authorized a.permissions.edit_state
                ~is_keep:keeping_app_state
                ~updated:
                  (`Ok
                    (Vector.map2 app_state a.snapp.app_state
                       ~f:(Set_or_keep.Checked.set_or_keep ~if_:Field.if_))))
        in
        Option.iter tag ~f:(fun t ->
            Pickles.Side_loaded.in_circuit t
              (Lazy.force a.snapp.verification_key.data)) ;
        let verification_key =
          update_authorized a.permissions.set_verification_key
            ~is_keep:(Set_or_keep.Checked.is_keep verification_key)
            ~updated:
              (`Ok
                (Set_or_keep.Checked.set_or_keep ~if_:Field.if_ verification_key
                   (Lazy.force a.snapp.verification_key.hash)))
        in
        let rollup_state, last_rollup_slot =
          let [ s1'; s2'; s3'; s4'; s5' ] = a.snapp.rollup_state in
          let last_rollup_slot = a.snapp.last_rollup_slot in
          let is_this_slot =
            !(Mina_numbers.Global_slot.Checked.equal txn_global_slot
                last_rollup_slot)
          in
          (* Push events to s1 *)
          let is_empty = !(Party.Events.is_empty_var rollup_events) in
          let s1 =
            Field.if_ is_empty ~then_:s1'
              ~else_:(Party.Rollup_events.push_events_checked s1' rollup_events)
          in
          (* Shift along if last update wasn't this slot *)
          let is_full_and_different_slot =
            Boolean.((not is_empty) && is_this_slot)
          in
          let s5 = Field.if_ is_full_and_different_slot ~then_:s5' ~else_:s4' in
          let s4 = Field.if_ is_full_and_different_slot ~then_:s4' ~else_:s3' in
          let s3 = Field.if_ is_full_and_different_slot ~then_:s3' ~else_:s2' in
          let s2 = Field.if_ is_full_and_different_slot ~then_:s2' ~else_:s1' in
          let new_global_slot =
            !(Mina_numbers.Global_slot.Checked.if_ is_empty
                ~then_:last_rollup_slot ~else_:txn_global_slot)
          in
          let new_rollup_state =
            ( ([ s1; s2; s3; s4; s5 ] : _ Pickles_types.Vector.t)
            , new_global_slot )
          in
          update_authorized a.permissions.edit_rollup_state ~is_keep:is_empty
            ~updated:(`Ok new_rollup_state)
        in
        let snapp_version =
          (* Current snapp version. Upgrade mechanism should live here. *)
          Mina_numbers.Snapp_version.(Checked.constant zero)
        in
        { Snapp_account.verification_key =
            (* Big hack. This relies on the fact that the "data" is not
               used for computing the hash of the snapp account. We can't
               provide the verification key since it's not available here. *)
            { With_hash.hash = lazy verification_key
            ; data = lazy (failwith "unused")
            }
        ; app_state
        ; snapp_version
        ; rollup_state
        ; last_rollup_slot
        ; proved_state
        }
      in
      let snapp_uri =
        update_authorized a.permissions.set_snapp_uri
          ~is_keep:(Set_or_keep.Checked.is_keep snapp_uri)
          ~updated:
            (`Ok
              (Set_or_keep.Checked.set_or_keep ~if_:Data_as_hash.if_ snapp_uri
                 a.snapp_uri))
      in
      let token_symbol =
        update_authorized a.permissions.set_snapp_uri
          ~is_keep:(Set_or_keep.Checked.is_keep token_symbol)
          ~updated:
            (`Ok
              (Set_or_keep.Checked.set_or_keep ~if_:Account.Token_symbol.if_
                 token_symbol a.token_symbol))
      in
      let delegate =
        let base_delegate =
          (* New accounts should have the delegate equal to the public key of the account. *)
          !(Public_key.Compressed.Checked.if_ is_new ~then_:pk
              ~else_:a.delegate)
        in
        update_authorized a.permissions.set_delegate
          ~is_keep:(Set_or_keep.Checked.is_keep delegate)
          ~updated:
            (`Ok
              (Set_or_keep.Checked.set_or_keep
                 ~if_:(fun b ~then_ ~else_ ->
                   !(Public_key.Compressed.Checked.if_ b ~then_ ~else_))
                 delegate base_delegate))
      in
      let permissions =
        update_authorized a.permissions.set_permissions
          ~is_keep:(Set_or_keep.Checked.is_keep permissions)
          ~updated:
            (`Ok
              (Set_or_keep.Checked.set_or_keep ~if_:Permissions.Checked.if_
                 permissions a.permissions))
      in
      let nonce =
        !( match predicate with
         | Full _ ->
             Account.Nonce.Checked.succ a.nonce
         | Nonce_or_accept { accept; _ } ->
             Account.Nonce.Checked.succ_if a.nonce (Boolean.not accept) )
      in
      let a : Account.Checked.Unhashed.t =
        { a with
          balance
        ; snapp
        ; delegate
        ; permissions
        ; timing
        ; nonce
        ; public_key = pk
        ; snapp_uri
        ; token_symbol
        }
      in
      (a, `proof_must_verify proof_must_verify)

    let create_checker () =
      let r = ref [] in
      let finished = ref false in
      ( (fun ?label:_ x ->
          if finished.contents then failwith "finished"
          else r := x :: r.contents)
      , fun () ->
          finished := true ;
          Impl.Boolean.all r.contents )

    module type Single_inputs = sig
      val constraint_constants : Genesis_constants.Constraint_constants.t

      val spec : single

      val snapp_statement : (int * Snapp_statement.Checked.t) option
    end

    type party =
      { party : (Party.Predicated.Checked.t, Impl.Field.t) With_hash.t
      ; control : Control.t Prover_value.t
      }

    module Single (I : Single_inputs) = struct
      open I

      let { predicate_type; auth_type; is_start } = spec

      module V = Prover_value
      open Impl

      module Inputs = struct
        module Transaction_commitment = struct
          type t = Field.t

          let if_ = Field.if_

          let empty = Field.constant Parties.Transaction_commitment.empty
        end

        module Bool = struct
          include Boolean

          type t = var

          let assert_ = Assert.is_true
        end

        module Ledger = struct
          type t = Ledger_hash.var * Sparse_ledger.t V.t

          let if_ b ~then_:(xt, rt) ~else_:(xe, re) =
            ( run_checked (Ledger_hash.if_ b ~then_:xt ~else_:xe)
            , V.if_ b ~then_:rt ~else_:re )

          let empty ~depth () : t =
            let t = Sparse_ledger.empty ~depth () in
            ( Ledger_hash.var_of_t (Sparse_ledger.merkle_root t)
            , V.create (fun () -> t) )
        end

        module Parties = struct
          module Opt = struct
            open Snapp_basic

            type 'a t = (Bool.t, 'a) Flagged_option.t

            let is_some = Flagged_option.is_some

            let map x ~f = Flagged_option.map ~f x

            let or_default ~if_ x ~default =
              if_ (is_some x) ~then_:(Flagged_option.data x) ~else_:default

            let or_exn x =
              Bool.assert_ (is_some x) ;
              Flagged_option.data x
          end

          type party_or_stack =
            Field.t
            * (Party.t * unit, Parties.Digest.t) Parties.Party_or_stack.t V.t

          type t =
            Field.t
            * (Party.t * unit, Parties.Digest.t) Parties.Party_or_stack.t list
              V.t

          let if_ b ~then_:(xt, rt) ~else_:(xe, re) =
            (Field.if_ b ~then_:xt ~else_:xe, V.if_ b ~then_:rt ~else_:re)

          let empty = Field.constant Parties.Party_or_stack.With_hashes.empty

          let is_empty (x, _) = Field.equal empty x

          let empty = (empty, V.create (fun () -> []))

          let hash_cons hash h_tl =
            Random_oracle.Checked.hash ~init:Hash_prefix_states.party_cons
              [| hash; h_tl |]

          let pop_exn ((h, r) : t) : party_or_stack * t =
            let hd_r = V.create (fun () -> V.get r |> List.hd_exn) in
            let tl_r = V.create (fun () -> V.get r |> List.tl_exn) in
            let party_or_stack, stack =
              exists
                Typ.(Field.typ * Field.typ)
                ~compute:(fun () ->
                  ( V.get hd_r |> Parties.Party_or_stack.With_hashes.hash
                  , V.get tl_r |> Parties.Party_or_stack.With_hashes.stack_hash
                  ))
            in
            let h' = hash_cons party_or_stack stack in
            Field.Assert.equal h h' ;
            ((party_or_stack, hd_r), (stack, tl_r))

          let as_stack ((h, r) : party_or_stack) : t Opt.t =
            (* NB: Don't need to check here, since interpreting a stack as a
               party or party as a stack implies a hash collision.
            *)
            let is_some =
              exists Boolean.typ ~compute:(fun () ->
                  match V.get r with Party _ -> false | Stack _ -> true)
            in
            let data =
              ( h
              , V.create (fun () ->
                    match V.get r with Party _ -> [] | Stack (xs, _) -> xs) )
            in
            { Snapp_basic.Flagged_option.is_some; data }

          let pop_party_exn ((h, r) : t) : party * t =
            let first_party =
              V.create (fun () ->
                  match V.get r |> List.hd_exn with
                  | Party ((party, ()), _) ->
                      party
                  | Stack _ ->
                      failwith "pop_party_exn")
            in
            let body, tl =
              exists
                Typ.(Party.Body.typ () * field)
                ~compute:(fun () ->
                  let p = V.get first_party in
                  let h =
                    V.get r |> List.tl_exn
                    |> Parties.Party_or_stack.With_hashes.stack_hash
                  in
                  (p.data.body, h))
            in
            let predicate : Party.Predicate.Checked.t =
              match predicate_type with
              | `Nonce_or_accept ->
                  let nonce, accept =
                    exists (Typ.tuple2 Account.Nonce.typ Boolean.typ)
                      ~compute:(fun () ->
                        match (V.get first_party).data.predicate with
                        | Nonce n ->
                            (n, false)
                        | Accept ->
                            (Account.Nonce.zero, true)
                        | Full _ ->
                            failwith
                              "first party should have nonce as predicate")
                  in
                  Nonce_or_accept { nonce; accept }
              | `Full ->
                  Full
                    (exists (Party.Predicate.typ ()) ~compute:(fun () ->
                         (V.get first_party).data.predicate))
            in
            let auth =
              V.(create (fun () -> (V.get first_party).authorization))
            in
            let party : Party.Predicated.Checked.t = { body; predicate } in
            let party =
              With_hash.of_data party ~hash_data:Party.Predicated.Checked.digest
            in
            let actual_h =
              Random_oracle.Checked.hash ~init:Hash_prefix_states.party_cons
                [| party.hash; tl |]
            in
            Field.Assert.equal h actual_h ;
            ( { party; control = auth }
            , (tl, V.(create (fun () -> List.tl_exn (get r)))) )

          let pop_stack ((h, r) : t) : (t * t) Opt.t =
            let hd_r =
              V.create (fun () ->
                  match V.get r |> List.hd with
                  | Some (Stack (x, _)) ->
                      x
                  | _ ->
                      [])
            in
            let tl_r =
              V.create (fun () ->
                  V.get r |> List.tl |> Option.value ~default:[])
            in
            let party_or_stack, stack =
              exists
                Typ.(Field.typ * Field.typ)
                ~compute:(fun () ->
                  ( V.get hd_r |> Parties.Party_or_stack.With_hashes.stack_hash
                  , V.get tl_r |> Parties.Party_or_stack.With_hashes.stack_hash
                  ))
            in
            let h' = hash_cons party_or_stack stack in
            (* NB: Don't need to check here, since interpreting a stack as a
               party or party as a stack implies a hash collision.
            *)
            let is_some = Field.equal h h' in
            let data = ((party_or_stack, hd_r), (stack, tl_r)) in
            { Snapp_basic.Flagged_option.is_some; data }

          let push_stack ((h_hd, r_hd) : t) ~onto:((h_tl, r_tl) : t) : t =
            let h = hash_cons h_hd h_tl in
            let r =
              V.create (fun () ->
                  let hd_stack = V.get r_hd in
                  let tl = V.get r_tl in
                  Parties.Party_or_stack.Stack
                    (hd_stack, As_prover.read Field.typ h)
                  :: tl)
            in
            (h, r)
        end

        module Party = struct
          type t = party

          let delta (t : t) = t.party.data.body.delta
        end

        module Account = struct
          type t = (Account.Checked.Unhashed.t, Field.t) With_hash.t
        end

        module Amount = struct
          type t = Amount.Checked.t

          module Signed = struct
            type t = Amount.Signed.Checked.t

            let is_pos (t : t) = Sgn.Checked.is_pos t.sgn

            let negate = Amount.Signed.Checked.negate
          end

          let if_ b ~then_ ~else_ =
            run_checked (Amount.Checked.if_ b ~then_ ~else_)

          let zero = Amount.(var_of_t zero)

          let add_flagged x y = run_checked (Amount.Checked.add_flagged x y)

          let add_signed_flagged (x : t) (y : Signed.t) =
            run_checked (Amount.Checked.add_signed_flagged x y)
        end

        module Token_id = struct
          type t = Token_id.Checked.t

          let if_ b ~then_ ~else_ =
            run_checked (Token_id.Checked.if_ b ~then_ ~else_)

          let equal x y = run_checked (Token_id.Checked.equal x y)

          let default = Token_id.(var_of_t default)

          let invalid = Token_id.(var_of_t invalid)
        end
      end

      module Env = struct
        open Inputs

        type t =
          < party : Party.t
          ; account : Account.t
          ; ledger : Ledger.t
          ; amount : Amount.t
          ; bool : Bool.t
          ; token_id : Token_id.t
          ; global_state : Global_state.t
          ; inclusion_proof : (Bool.t * Field.t) list
          ; parties : Parties.t
          ; local_state :
              ( Parties.t
              , Token_id.t
              , Amount.t
              , Ledger.t
              , Bool.t
              , Transaction_commitment.t )
              Parties_logic.Local_state.t
          ; protocol_state_predicate : Snapp_predicate.Protocol_state.Checked.t
          ; transaction_commitment : Transaction_commitment.t >
      end

      include Parties_logic.Make (Inputs)

      let perform (type r) (eff : (r, Env.t) Parties_logic.Eff.t) : r =
        let body_id (body : Party.Body.Checked.t) =
          let open As_prover in
          Account_id.create
            (read Public_key.Compressed.typ body.pk)
            (read Token_id.typ body.token_id)
        in
        let idx ledger id = Sparse_ledger.find_index_exn ledger id in
        let account_with_hash (account : Account.Checked.Unhashed.t) =
          With_hash.of_data account ~hash_data:(fun a ->
              let a =
                { a with
                  snapp =
                    ( Snapp_account.Checked.digest a.snapp
                    , As_prover.Ref.create (fun () -> None) )
                }
              in
              run_checked (Account.Checked.digest a))
        in
        match eff with
        | Get_global_ledger g ->
            g.ledger
        | Transaction_commitment_on_start
            { start_party = _
            ; other_parties = other_parties, _
            ; protocol_state_predicate
            } -> (
            match is_start with
            | `No ->
                assert false
            | `Yes | `Compute_in_circuit ->
                Parties.Transaction_commitment.Checked.create
                  ~other_parties_hash:other_parties
                  ~protocol_state_predicate_hash:
                    (Snapp_predicate.Protocol_state.Checked.digest
                       protocol_state_predicate) )
        | Get_account ({ party; _ }, (_root, ledger)) ->
            let idx =
              V.map ledger ~f:(fun l -> idx l (body_id party.data.body))
            in
            let account =
              exists Account.Checked.Unhashed.typ ~compute:(fun () ->
                  Sparse_ledger.get_exn (V.get ledger) (V.get idx))
            in
            let account = account_with_hash account in
            let incl =
              exists
                Typ.(
                  list ~length:constraint_constants.ledger_depth
                    (Boolean.typ * field))
                ~compute:(fun () ->
                  List.map
                    (Sparse_ledger.path_exn (V.get ledger) (V.get idx))
                    ~f:(fun x ->
                      match x with
                      | `Left h ->
                          (false, h)
                      | `Right h ->
                          (true, h)))
            in
            (account, incl)
        | Check_inclusion ((root, _), account, incl) ->
            with_label __LOC__
              (fun () -> Field.Assert.equal (implied_root account incl))
              (Ledger_hash.var_to_hash_packed root)
        | Check_protocol_state_predicate (protocol_state_predicate, global_state)
          ->
            Snapp_predicate.Protocol_state.Checked.check
              protocol_state_predicate global_state.protocol_state
        | Check_predicate (_is_start, { party; _ }, account, _global) -> (
            match party.data.predicate with
            | Nonce_or_accept { nonce; accept } ->
                Boolean.( || ) accept
                  (run_checked
                     (Account.Nonce.Checked.equal nonce account.data.nonce))
            | Full p ->
                Snapp_predicate.Account.Checked.check p account.data )
        | Set_account ((_root, ledger), a, incl) ->
            ( implied_root a incl |> Ledger_hash.var_of_hash_packed
            , V.map ledger
                ~f:
                  As_prover.(
                    let account_typ =
                      let snapp :
                          ( Snapp_account.Checked.t
                          , Snapp_account.t option )
                          Typ.t =
                        let open Snapp_account.Poly in
                        let vk :
                            ( ( Pickles.Side_loaded.Verification_key.Checked.t
                                Lazy.t
                              , Pickles.Impls.Step.Field.t Lazy.t )
                              With_hash.t
                            , ( Side_loaded_verification_key.t
                              , Field.Constant.t )
                              With_hash.t
                              option )
                            Typ.t =
                          { store = (fun _ -> failwith "unused")
                          ; check = (fun _ -> failwith "unused")
                          ; alloc = Free (Alloc (fun _ -> failwith "unused"))
                          ; read =
                              Snarky_backendless.Typ_monads.Read.(
                                fun v ->
                                  let%map h = read (Lazy.force v.hash) in
                                  Some
                                    { With_hash.data =
                                        Pickles.Side_loaded.Verification_key
                                        .dummy
                                    ; hash = h
                                    })
                          }
                        in
                        (* TODO: Refactor. This hacking around the vk is a code smell *)
                        Typ.of_hlistable
                          [ Snapp_state.typ Field.typ
                          ; vk
                          ; Mina_numbers.Snapp_version.typ
                          ; Pickles_types.Vector.typ Field.typ
                              Pickles_types.Nat.N5.n
                          ; Mina_numbers.Global_slot.typ
                          ; Boolean.typ
                          ]
                          ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
                          ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
                        |> Typ.transport
                             ~there:(fun x -> Option.value_exn x)
                             ~back:(fun x -> Some x)
                      in
                      Account.typ' snapp
                    in
                    fun ledger ->
                      let a : Account.t = read account_typ a.data in
                      let idx = idx ledger (Account.identifier a) in
                      Sparse_ledger.set_exn ledger idx a) )
        | Modify_global_excess (global, f) ->
            { global with fee_excess = f global.fee_excess }
        | Modify_global_ledger { global_state; ledger; should_update } ->
            { global_state with
              ledger =
                Inputs.Ledger.if_ should_update ~then_:ledger
                  ~else_:global_state.ledger
            }
        | Party_token_id { party; _ } ->
            party.data.body.token_id
        | Check_auth_and_update_account
            { is_start = is_actually_start
            ; at_party = at_party, _
            ; global_state
            ; party = { party; control; _ }
            ; account
            ; transaction_commitment
            ; inclusion_proof = _
            } ->
            ( match (auth_type, snapp_statement) with
            | Proof, Some (i, s) ->
                Pickles.Side_loaded.in_circuit (side_loaded i)
                  (Lazy.force account.data.snapp.verification_key.data) ;
                Snapp_statement.Checked.Assert.equal
                  { transaction = transaction_commitment; at_party }
                  s
            | (Signature | None_given), None ->
                ()
            | Proof, None | (Signature | None_given), Some _ ->
                assert false ) ;
            let transaction_commitment =
              let with_party () =
                Parties.Transaction_commitment.Checked.with_fee_payer
                  transaction_commitment ~fee_payer_hash:party.hash
              in
              match is_start with
              | `No ->
                  transaction_commitment
              | `Yes ->
                  with_party ()
              | `Compute_in_circuit ->
                  Inputs.Transaction_commitment.if_ is_actually_start
                    ~then_:(with_party ()) ~else_:transaction_commitment
            in
            let add_check, checks_succeeded = create_checker () in
            let signature_verifies =
              match auth_type with
              | None_given | Proof ->
                  Boolean.false_
              | Signature ->
                  let signature =
                    exists Signature_lib.Schnorr.Signature.typ
                      ~compute:(fun () ->
                        match V.get control with
                        | Signature s ->
                            s
                        | None_given ->
                            Signature.dummy
                        | Proof _ ->
                            assert false)
                  in
                  run_checked
                    (let%bind (module S) =
                       Tick.Inner_curve.Checked.Shifted.create ()
                     in
                     signature_verifies
                       ~shifted:(module S)
                       ~payload_digest:transaction_commitment signature
                       account.data.public_key)
            in
            let account', `proof_must_verify proof_must_verify =
              let tag =
                Option.map snapp_statement ~f:(fun (i, _) -> side_loaded i)
              in
              apply_body ~constraint_constants ?tag
                ~txn_global_slot:global_state.protocol_state.curr_global_slot
                ~add_check
                ~check_auth:(fun t ->
                  Permissions.Auth_required.Checked.spec_eval
                    ~signature_verifies t)
                party.data account.data
            in
            let proof_must_verify = proof_must_verify () in
            let checks_succeeded = checks_succeeded () in
            let success =
              match auth_type with
              | None_given | Signature ->
                  Boolean.((not proof_must_verify) && checks_succeeded)
              | Proof ->
                  (* We always assert that the proof verifies. *)
                  checks_succeeded
            in
            (account_with_hash account', success)
        | Balance account ->
            Balance.Checked.to_amount account.data.balance
    end

    let main ?(witness : Witness.t option) (spec : Spec.t) ~constraint_constants
        snapp_statements (statement : Statement.With_sok.Checked.t) =
      let open Impl in
      run_checked (dummy_constraints ()) ;
      let ( ! ) x = Option.value_exn x in
      let state_body =
        exists (Mina_state.Protocol_state.Body.typ ~constraint_constants)
          ~compute:(fun () -> !witness.state_body)
      in
      let module V = Prover_value in
      let `Needs_some_work_for_snapps_on_mainnet = Mina_base.Util.todo_snapps in
      (* TODO: Must check the state_body against the pending coinbase stack somehow. *)
      let init : Global_state.t * _ Parties_logic.Local_state.t =
        let g : Global_state.t =
          { ledger =
              ( statement.source.ledger
              , V.create (fun () -> !witness.global_ledger) )
          ; fee_excess = Amount.(var_of_t zero)
          ; protocol_state =
              Mina_state.Protocol_state.Body.view_checked state_body
          }
        in
        let l : _ Parties_logic.Local_state.t =
          { parties =
              ( statement.source.local_state.parties
              , V.create (fun () -> !witness.local_state_init.parties) )
          ; call_stack =
              ( statement.source.local_state.call_stack
              , V.create (fun () -> !witness.local_state_init.call_stack) )
          ; transaction_commitment =
              statement.source.local_state.transaction_commitment
          ; token_id = statement.source.local_state.token_id
          ; excess = statement.source.local_state.excess
          ; ledger =
              ( statement.source.local_state.ledger
              , V.create (fun () -> !witness.local_state_init.ledger) )
          ; success = statement.source.local_state.success
          }
        in
        (g, l)
      in
      let start_parties =
        As_prover.Ref.create (fun () -> !witness.start_parties)
      in
      let (global, local), snapp_statements =
        List.fold_left spec ~init:(init, snapp_statements)
          ~f:(fun (((_, local) as acc), statements) party_spec ->
            let snapp_statement, statements =
              match party_spec.auth_type with
              | Signature | None_given ->
                  (None, statements)
              | Proof -> (
                  match statements with
                  | [] ->
                      assert false
                  | s :: ss ->
                      (Some s, ss) )
            in
            let module S = Single (struct
              let constraint_constants = constraint_constants

              let spec = party_spec

              let snapp_statement = snapp_statement
            end) in
            let finish v =
              let open Parties_logic.Start_data in
              let ps =
                V.map v ~f:(function
                  | `Skip ->
                      []
                  | `Start p ->
                      Party.of_signed p.parties.Parties.fee_payer
                      :: p.parties.Parties.other_parties
                      |> List.map ~f:(fun party -> (party, ()))
                      |> Parties.Party_or_stack.With_hashes.of_parties_list)
              in
              let h =
                exists Field.typ ~compute:(fun () ->
                    Parties.Party_or_stack.With_hashes.stack_hash (V.get ps))
              in
              let start_data =
                { Parties_logic.Start_data.parties = (h, ps)
                ; protocol_state_predicate =
                    exists Snapp_predicate.Protocol_state.typ
                      ~compute:(fun () ->
                        match V.get v with
                        | `Skip ->
                            Snapp_predicate.Protocol_state.accept
                        | `Start p ->
                            p.protocol_state_predicate)
                }
              in
              S.apply ~constraint_constants
                ~is_start:
                  ( match party_spec.is_start with
                  | `No ->
                      `No
                  | `Yes ->
                      `Yes start_data
                  | `Compute_in_circuit ->
                      `Compute start_data )
                S.{ perform }
                acc
            in
            let acc' =
              match party_spec.is_start with
              | `No ->
                  S.apply ~constraint_constants ~is_start:`No S.{ perform } acc
              | `Compute_in_circuit ->
                  V.create (fun () ->
                      match As_prover.Ref.get start_parties with
                      | [] ->
                          `Skip
                      | p :: ps ->
                          let should_pop =
                            Field.Constant.equal Parties.Party_or_stack.empty
                              (As_prover.read_var (fst local.parties))
                          in
                          if should_pop then (
                            As_prover.Ref.set start_parties ps ;
                            `Start p )
                          else `Skip)
                  |> finish
              | `Yes ->
                  as_prover
                    As_prover.(
                      fun () ->
                        [%test_eq: Impl.Field.Constant.t]
                          Parties.Party_or_stack.empty
                          (read_var (fst local.parties))) ;
                  V.create (fun () ->
                      match As_prover.Ref.get start_parties with
                      | [] ->
                          assert false
                      | p :: ps ->
                          As_prover.Ref.set start_parties ps ;
                          `Start p)
                  |> finish
            in
            (acc', statements))
      in
      assert (List.is_empty snapp_statements) ;
      with_label __LOC__ (fun () ->
          Local_state.Checked.assert_equal statement.target.local_state
            { local with
              parties = fst local.parties
            ; call_stack = fst local.call_stack
            ; ledger = fst local.ledger
            }) ;
      with_label __LOC__ (fun () ->
          run_checked
            (Frozen_ledger_hash.assert_equal (fst global.ledger)
               statement.target.ledger)) ;
      with_label __LOC__ (fun () ->
          run_checked
            (Amount.Checked.assert_equal statement.supply_increase
               Amount.(var_of_t zero))) ;
      with_label __LOC__ (fun () ->
          run_checked
            (Fee_excess.assert_equal_checked statement.fee_excess
               { fee_token_l = Token_id.(var_of_t default)
               ; fee_excess_l =
                   Fee.Signed.Checked.of_unsigned
                     (Amount.Checked.to_fee (fst init).fee_excess)
               ; fee_token_r = Token_id.(var_of_t default)
               ; fee_excess_r =
                   Fee.Signed.Checked.of_unsigned
                     (Amount.Checked.to_fee global.fee_excess)
               })) ;
      let `Needs_some_work_for_snapps_on_mainnet = Mina_base.Util.todo_snapps in
      (* TODO: Check various consistency equalities between local and global and the statement *)
      ()

    (* Horrible hack :( *)
    let witness : Witness.t option ref = ref None

    let rule (type a b c d) ~constraint_constants ~proof_level
        (t : (a, b, c, d) Basic.t_typed) :
        ( a
        , b
        , c
        , d
        , Statement.With_sok.var
        , Statement.With_sok.t )
        Pickles.Inductive_rule.t =
      let open Hlist in
      let open Basic in
      let module M = H4.T (Pickles.Tag) in
      let s = Basic.spec t in
      let prev_should_verify =
        match proof_level with
        | Genesis_constants.Proof_level.Full ->
            true
        | _ ->
            false
      in
      let b = Boolean.var_of_value prev_should_verify in
      match t with
      | Proved ->
          { identifier = "proved"
          ; prevs = M.[ side_loaded 0 ]
          ; main_value = (fun [ _ ] _ -> [ prev_should_verify ])
          ; main =
              (fun [ snapp_statement ] stmt ->
                main ?witness:!witness s ~constraint_constants
                  (List.mapi [ snapp_statement ] ~f:(fun i x -> (i, x)))
                  stmt ;
                [ b ])
          }
      | Opt_signed_unsigned ->
          { identifier = "opt_signed-unsigned"
          ; prevs = M.[]
          ; main_value = (fun [] _ -> [])
          ; main =
              (fun [] stmt ->
                main ?witness:!witness s ~constraint_constants [] stmt ;
                [])
          }
      | Opt_signed_opt_signed ->
          { identifier = "opt_signed-opt_signed"
          ; prevs = M.[]
          ; main_value = (fun [] _ -> [])
          ; main =
              (fun [] stmt ->
                main ?witness:!witness s ~constraint_constants [] stmt ;
                [])
          }
      | Opt_signed ->
          { identifier = "opt_signed"
          ; prevs = M.[]
          ; main_value = (fun [] _ -> [])
          ; main =
              (fun [] stmt ->
                main ?witness:!witness s ~constraint_constants [] stmt ;
                [])
          }
  end

  type _ Snarky_backendless.Request.t +=
    | Transaction : Transaction_union.t Snarky_backendless.Request.t
    | State_body :
        Mina_state.Protocol_state.Body.Value.t Snarky_backendless.Request.t
    | Init_stack : Pending_coinbase.Stack.t Snarky_backendless.Request.t

  let%snarkydef apply_tagged_transaction
      ~(constraint_constants : Genesis_constants.Constraint_constants.t)
      (type shifted)
      (shifted : (module Inner_curve.Checked.Shifted.S with type t = shifted))
      root pending_coinbase_stack_init pending_coinbase_stack_before
      pending_coinbase_after next_available_token state_body
      ({ signer; signature; payload } as txn : Transaction_union.var) =
    let tag = payload.body.tag in
    let is_user_command = Transaction_union.Tag.Unpacked.is_user_command tag in
    let%bind () =
      [%with_label "Check transaction signature"]
        (check_signature shifted ~payload ~is_user_command ~signer ~signature)
    in
    let%bind signer_pk = Public_key.compress_var signer in
    let%bind () =
      [%with_label "Fee-payer must sign the transaction"]
        ((* TODO: Enable multi-sig. *)
         Public_key.Compressed.Checked.Assert.equal signer_pk
           payload.common.fee_payer_pk)
    in
    (* Compute transaction kind. *)
    let is_payment = Transaction_union.Tag.Unpacked.is_payment tag in
    let is_mint_tokens = Transaction_union.Tag.Unpacked.is_mint_tokens tag in
    let is_stake_delegation =
      Transaction_union.Tag.Unpacked.is_stake_delegation tag
    in
    let is_create_account =
      Transaction_union.Tag.Unpacked.is_create_account tag
    in
    let is_fee_transfer = Transaction_union.Tag.Unpacked.is_fee_transfer tag in
    let is_coinbase = Transaction_union.Tag.Unpacked.is_coinbase tag in
    let fee_token = payload.common.fee_token in
    let%bind fee_token_invalid =
      Token_id.(Checked.equal fee_token (var_of_t invalid))
    in
    let%bind fee_token_default =
      Token_id.(Checked.equal fee_token (var_of_t default))
    in
    let token = payload.body.token_id in
    let%bind token_invalid =
      Token_id.(Checked.equal token (var_of_t invalid))
    in
    let%bind token_default =
      Token_id.(Checked.equal token (var_of_t default))
    in
    let%bind () =
      Checked.all_unit
        [ [%with_label
            "Token_locked value is compatible with the transaction kind"]
            (Boolean.Assert.any
               [ Boolean.not payload.body.token_locked; is_create_account ])
        ; [%with_label "Token_locked cannot be used with the default token"]
            (Boolean.Assert.any
               [ Boolean.not payload.body.token_locked
               ; Boolean.not token_default
               ])
        ]
    in
    let%bind () =
      [%with_label "Validate tokens"]
        (Checked.all_unit
           [ [%with_label "Fee token is valid"]
               Boolean.(Assert.is_true (not fee_token_invalid))
           ; [%with_label
               "Fee token is default or command allows non-default fee"]
               (Boolean.Assert.any
                  [ fee_token_default
                  ; is_payment
                  ; is_mint_tokens
                  ; is_stake_delegation
                  ; is_fee_transfer
                  ])
           ; (* TODO: Remove this check and update the transaction snark once we
                have an exchange rate mechanism. See issue #4447.
             *)
             [%with_label "Fees in tokens disabled"]
               (Boolean.Assert.is_true fee_token_default)
           ; [%with_label "Token is valid or command allows invalid token"]
               Boolean.(Assert.any [ not token_invalid; is_create_account ])
           ; [%with_label
               "Token is default or command allows non-default token"]
               (Boolean.Assert.any
                  [ token_default
                  ; is_payment
                  ; is_create_account
                  ; is_mint_tokens
                    (* TODO: Enable this when fees in tokens are enabled. *)
                    (*; is_fee_transfer*)
                  ])
           ; [%with_label
               "Token is non-default or command allows default token"]
               Boolean.(
                 Assert.any
                   [ not token_default
                   ; is_payment
                   ; is_stake_delegation
                   ; is_create_account
                   ; is_fee_transfer
                   ; is_coinbase
                   ])
           ])
    in
    let current_global_slot =
      Mina_state.Protocol_state.Body.consensus_state state_body
      |> Consensus.Data.Consensus_state.global_slot_since_genesis_var
    in
    let%bind creating_new_token =
      Boolean.(is_create_account &&& token_invalid)
    in
    (* Query user command predicted failure/success. *)
    let%bind user_command_failure =
      User_command_failure.compute_as_prover ~constraint_constants
        ~txn_global_slot:current_global_slot ~creating_new_token
        ~next_available_token txn
    in
    let%bind user_command_fails =
      User_command_failure.any user_command_failure
    in
    let%bind next_available_token_after, token =
      let%bind token =
        Token_id.Checked.if_ creating_new_token ~then_:next_available_token
          ~else_:token
      in
      let%bind will_create_new_token =
        Boolean.(creating_new_token &&& not user_command_fails)
      in
      let%map next_available_token =
        Token_id.Checked.next_if next_available_token will_create_new_token
      in
      (next_available_token, token)
    in
    let fee = payload.common.fee in
    let receiver = Account_id.Checked.create payload.body.receiver_pk token in
    let source = Account_id.Checked.create payload.body.source_pk token in
    (* Information for the fee-payer. *)
    let nonce = payload.common.nonce in
    let fee_payer =
      Account_id.Checked.create payload.common.fee_payer_pk fee_token
    in
    let%bind () =
      [%with_label "Check slot validity"]
        ( Global_slot.Checked.(current_global_slot <= payload.common.valid_until)
        >>= Boolean.Assert.is_true )
    in

    (* Check coinbase stack. Protocol state body is pushed into the Pending
       coinbase stack once per block. For example, consider any two
       transactions in a block. Their pending coinbase stacks would be:

       transaction1: s1 -> t1 = s1+ protocol_state_body + maybe_coinbase
       transaction2: t1 -> t1 + maybe_another_coinbase
         (Note: protocol_state_body is not pushed again)

       However, for each transaction, we need to constrain the protocol state
       body. This is done is by using the stack ([init_stack]) without the
       current protocol state body, pushing the state body to it in every
       transaction snark and checking if it matches the target.
       We also need to constrain the source for the merges to work correctly.
       Basically,

       init_stack + protocol_state_body + maybe_coinbase = target
       AND
       init_stack = source || init_stack + protocol_state_body = source *)

    (* These are all the possible cases:

        Init_stack     Source                 Target
       --------------------------------------------------------------
         i               i                       i + state
         i               i                       i + state + coinbase
         i               i + state               i + state
         i               i + state               i + state + coinbase
         i + coinbase    i + state + coinbase    i + state + coinbase
    *)
    let%bind () =
      [%with_label "Compute coinbase stack"]
        (let%bind state_body_hash =
           Mina_state.Protocol_state.Body.hash_checked state_body
         in
         let%bind pending_coinbase_stack_with_state =
           Pending_coinbase.Stack.Checked.push_state state_body_hash
             pending_coinbase_stack_init
         in
         let%bind computed_pending_coinbase_stack_after =
           let coinbase =
             (Account_id.Checked.public_key receiver, payload.body.amount)
           in
           let%bind stack' =
             Pending_coinbase.Stack.Checked.push_coinbase coinbase
               pending_coinbase_stack_with_state
           in
           Pending_coinbase.Stack.Checked.if_ is_coinbase ~then_:stack'
             ~else_:pending_coinbase_stack_with_state
         in
         [%with_label "Check coinbase stack"]
           (let%bind correct_coinbase_target_stack =
              Pending_coinbase.Stack.equal_var
                computed_pending_coinbase_stack_after pending_coinbase_after
            in
            let%bind valid_init_state =
              let%bind equal_source =
                Pending_coinbase.Stack.equal_var pending_coinbase_stack_init
                  pending_coinbase_stack_before
              in
              let%bind equal_source_with_state =
                Pending_coinbase.Stack.equal_var
                  pending_coinbase_stack_with_state
                  pending_coinbase_stack_before
              in
              Boolean.(equal_source ||| equal_source_with_state)
            in
            Boolean.Assert.all
              [ correct_coinbase_target_stack; valid_init_state ]))
    in
    (* Interrogate failure cases. This value is created without constraints;
       the failures should be checked against potential failures to ensure
       consistency.
    *)
    let%bind () =
      [%with_label "A failing user command is a user command"]
        Boolean.(Assert.any [ is_user_command; not user_command_fails ])
    in
    let predicate_deferred =
      (* Predicate check is to be performed later if this is true. *)
      is_create_account
    in
    let%bind predicate_result =
      let%bind is_own_account =
        Public_key.Compressed.Checked.equal payload.common.fee_payer_pk
          payload.body.source_pk
      in
      let predicate_result =
        (* TODO: Predicates. *)
        Boolean.false_
      in
      Boolean.(is_own_account ||| predicate_result)
    in
    let%bind () =
      [%with_label "Check predicate failure against predicted"]
        (let%bind predicate_failed =
           Boolean.((not predicate_result) &&& not predicate_deferred)
         in
         assert_r1cs
           (predicate_failed :> Field.Var.t)
           (is_user_command :> Field.Var.t)
           (user_command_failure.predicate_failed :> Field.Var.t))
    in
    let account_creation_amount =
      Amount.Checked.of_fee
        Fee.(var_of_t constraint_constants.account_creation_fee)
    in
    let%bind is_zero_fee =
      fee |> Fee.var_to_number |> Number.to_var
      |> Field.(Checked.equal (Var.constant zero))
    in
    let is_coinbase_or_fee_transfer = Boolean.not is_user_command in
    let%bind can_create_fee_payer_account =
      (* Fee transfers and coinbases may create an account. We check the normal
         invariants to ensure that the account creation fee is paid.
      *)
      let%bind fee_may_be_charged =
        (* If the fee is zero, we do not create the account at all, so we allow
           this through. Otherwise, the fee must be the default.
        *)
        Boolean.(token_default ||| is_zero_fee)
      in
      Boolean.(is_coinbase_or_fee_transfer &&& fee_may_be_charged)
    in
    let%bind root_after_fee_payer_update =
      [%with_label "Update fee payer"]
        (Frozen_ledger_hash.modify_account_send
           ~depth:constraint_constants.ledger_depth root
           ~is_writeable:can_create_fee_payer_account fee_payer
           ~f:(fun ~is_empty_and_writeable account ->
             (* this account is:
                - the fee-payer for payments
                - the fee-payer for stake delegation
                - the fee-payer for account creation
                - the fee-payer for token minting
                - the fee-receiver for a coinbase
                - the second receiver for a fee transfer
             *)
             let%bind next_nonce =
               Account.Nonce.Checked.succ_if account.nonce is_user_command
             in
             let%bind () =
               [%with_label "Check fee nonce"]
                 (let%bind nonce_matches =
                    Account.Nonce.Checked.equal nonce account.nonce
                  in
                  Boolean.Assert.any
                    [ Boolean.not is_user_command; nonce_matches ])
             in
             let%bind receipt_chain_hash =
               let current = account.receipt_chain_hash in
               let%bind r =
                 Receipt.Chain_hash.Checked.cons (Signed_command payload)
                   current
               in
               Receipt.Chain_hash.Checked.if_ is_user_command ~then_:r
                 ~else_:current
             in
             let%bind is_empty_and_writeable =
               (* If this is a coinbase with zero fee, do not create the
                  account, since the fee amount won't be enough to pay for it.
               *)
               Boolean.(is_empty_and_writeable &&& not is_zero_fee)
             in
             let%bind should_pay_to_create =
               (* Coinbases and fee transfers may create, or we may be creating
                  a new token account. These are mutually exclusive, so we can
                  encode this as a boolean.
               *)
               let%bind is_create_account =
                 Boolean.(is_create_account &&& not user_command_fails)
               in
               Boolean.(is_empty_and_writeable ||| is_create_account)
             in
             let%bind amount =
               [%with_label "Compute fee payer amount"]
                 (let fee_payer_amount =
                    let sgn = Sgn.Checked.neg_if_true is_user_command in
                    Amount.Signed.create
                      ~magnitude:(Amount.Checked.of_fee fee)
                      ~sgn
                  in
                  (* Account creation fee for fee transfers/coinbases. *)
                  let%bind account_creation_fee =
                    let%map magnitude =
                      Amount.Checked.if_ should_pay_to_create
                        ~then_:account_creation_amount
                        ~else_:Amount.(var_of_t zero)
                    in
                    Amount.Signed.create ~magnitude ~sgn:Sgn.Checked.neg
                  in
                  Amount.Signed.Checked.(
                    add fee_payer_amount account_creation_fee))
             in
             let txn_global_slot = current_global_slot in
             let%bind `Min_balance _, timing =
               [%with_label "Check fee payer timing"]
                 (let%bind txn_amount =
                    Amount.Checked.if_
                      (Sgn.Checked.is_neg amount.sgn)
                      ~then_:amount.magnitude
                      ~else_:Amount.(var_of_t zero)
                  in
                  let balance_check ok =
                    [%with_label "Check fee payer balance"]
                      (Boolean.Assert.is_true ok)
                  in
                  let timed_balance_check ok =
                    [%with_label "Check fee payer timed balance"]
                      (Boolean.Assert.is_true ok)
                  in
                  check_timing ~balance_check ~timed_balance_check ~account
                    ~txn_amount ~txn_global_slot)
             in
             let%bind balance =
               [%with_label "Check payer balance"]
                 (Balance.Checked.add_signed_amount account.balance amount)
             in
             let%map public_key =
               Public_key.Compressed.Checked.if_ is_empty_and_writeable
                 ~then_:(Account_id.Checked.public_key fee_payer)
                 ~else_:account.public_key
             and token_id =
               Token_id.Checked.if_ is_empty_and_writeable
                 ~then_:(Account_id.Checked.token_id fee_payer)
                 ~else_:account.token_id
             and delegate =
               Public_key.Compressed.Checked.if_ is_empty_and_writeable
                 ~then_:(Account_id.Checked.public_key fee_payer)
                 ~else_:account.delegate
             in
             { Account.Poly.balance
             ; public_key
             ; token_id
             ; token_permissions = account.token_permissions
             ; token_symbol = account.token_symbol
             ; nonce = next_nonce
             ; receipt_chain_hash
             ; delegate
             ; voting_for = account.voting_for
             ; timing
             ; permissions = account.permissions
             ; snapp = account.snapp
             ; snapp_uri = account.snapp_uri
             }))
    in
    let%bind receiver_increase =
      (* - payments:         payload.body.amount
         - stake delegation: 0
         - account creation: 0
         - token minting:    payload.body.amount
         - coinbase:         payload.body.amount - payload.common.fee
         - fee transfer:     payload.body.amount
      *)
      [%with_label "Compute receiver increase"]
        (let%bind base_amount =
           let%bind zero_transfer =
             Boolean.any [ is_stake_delegation; is_create_account ]
           in
           Amount.Checked.if_ zero_transfer
             ~then_:(Amount.var_of_t Amount.zero)
             ~else_:payload.body.amount
         in
         (* The fee for entering the coinbase transaction is paid up front. *)
         let%bind coinbase_receiver_fee =
           Amount.Checked.if_ is_coinbase
             ~then_:(Amount.Checked.of_fee fee)
             ~else_:(Amount.var_of_t Amount.zero)
         in
         Amount.Checked.sub base_amount coinbase_receiver_fee)
    in
    let receiver_overflow = ref Boolean.false_ in
    let%bind root_after_receiver_update =
      [%with_label "Update receiver"]
        (Frozen_ledger_hash.modify_account_recv
           ~depth:constraint_constants.ledger_depth root_after_fee_payer_update
           receiver ~f:(fun ~is_empty_and_writeable account ->
             (* this account is:
                - the receiver for payments
                - the delegated-to account for stake delegation
                - the created account for an account creation
                - the receiver for minted tokens
                - the receiver for a coinbase
                - the first receiver for a fee transfer
             *)
             let%bind is_empty_failure =
               let%bind must_not_be_empty =
                 Boolean.(is_stake_delegation ||| is_mint_tokens)
               in
               Boolean.(is_empty_and_writeable &&& must_not_be_empty)
             in
             let%bind () =
               [%with_label "Receiver existence failure matches predicted"]
                 (Boolean.Assert.( = ) is_empty_failure
                    user_command_failure.receiver_not_present)
             in
             let%bind () =
               [%with_label "Receiver creation failure matches predicted"]
                 (let%bind is_nonempty_creating =
                    Boolean.((not is_empty_and_writeable) &&& is_create_account)
                  in
                  Boolean.Assert.( = ) is_nonempty_creating
                    user_command_failure.receiver_exists)
             in
             let is_empty_and_writeable =
               (* is_empty_and_writable && not is_empty_failure *)
               Boolean.Unsafe.of_cvar
               @@ Field.Var.(
                    sub (is_empty_and_writeable :> t) (is_empty_failure :> t))
             in
             let%bind should_pay_to_create =
               Boolean.(is_empty_and_writeable &&& not is_create_account)
             in
             let%bind () =
               [%with_label
                 "Check whether creation fails due to a non-default token"]
                 (let%bind token_should_not_create =
                    Boolean.(should_pay_to_create &&& Boolean.not token_default)
                  in
                  let%bind token_cannot_create =
                    Boolean.(token_should_not_create &&& is_user_command)
                  in
                  let%bind () =
                    [%with_label
                      "Check that account creation is paid in the default \
                       token for non-user-commands"]
                      ((* This expands to
                          [token_should_not_create =
                            token_should_not_create && is_user_command]
                          which is
                          - [token_should_not_create = token_should_not_create]
                            (ie. always satisfied) for user commands
                          - [token_should_not_create = false] for coinbases/fee
                            transfers.
                       *)
                       Boolean.Assert.( = ) token_should_not_create
                         token_cannot_create)
                  in
                  Boolean.Assert.( = ) token_cannot_create
                    user_command_failure.token_cannot_create)
             in
             let%bind balance =
               (* [receiver_increase] will be zero in the stake delegation
                  case.
               *)
               let%bind receiver_amount =
                 let%bind account_creation_amount =
                   Amount.Checked.if_ should_pay_to_create
                     ~then_:account_creation_amount
                     ~else_:Amount.(var_of_t zero)
                 in
                 let%bind amount_for_new_account, `Underflow underflow =
                   Amount.Checked.sub_flagged receiver_increase
                     account_creation_amount
                 in
                 let%bind () =
                   [%with_label
                     "Receiver creation fee failure matches predicted"]
                     (Boolean.Assert.( = ) underflow
                        user_command_failure.amount_insufficient_to_create)
                 in
                 Currency.Amount.Checked.if_ user_command_fails
                   ~then_:Amount.(var_of_t zero)
                   ~else_:amount_for_new_account
               in

               (* NOTE: Instead of capturing this as part of the user command
                  failures, we capture it inline here and bubble it out to a
                  reference. This behavior is still in line with the
                  out-of-snark transaction logic.

                  Updating [user_command_fails] to include this value from here
                  onwards will ensure that we do not update the source or
                  receiver accounts. The only places where [user_command_fails]
                  may have already affected behaviour are
                  * when the fee-payer is paying the account creation fee, and
                  * when a new token is created.
                  In both of these, this account is new, and will have a
                  balance of 0, so we can guarantee that there is no overflow.
               *)
               let%bind balance, `Overflow overflow =
                 Balance.Checked.add_amount_flagged account.balance
                   receiver_amount
               in
               let%bind () =
                 [%with_label "Overflow error only occurs in user commands"]
                   Boolean.(Assert.any [ is_user_command; not overflow ])
               in
               receiver_overflow := overflow ;
               Balance.Checked.if_ overflow ~then_:account.balance
                 ~else_:balance
             in
             let%bind user_command_fails =
               Boolean.(!receiver_overflow ||| user_command_fails)
             in
             let%bind is_empty_and_writeable =
               (* Do not create a new account if the user command will fail. *)
               Boolean.(is_empty_and_writeable &&& not user_command_fails)
             in
             let%bind may_delegate =
               (* Only default tokens may participate in delegation. *)
               Boolean.(is_empty_and_writeable &&& token_default)
             in
             let%map delegate =
               Public_key.Compressed.Checked.if_ may_delegate
                 ~then_:(Account_id.Checked.public_key receiver)
                 ~else_:account.delegate
             and public_key =
               Public_key.Compressed.Checked.if_ is_empty_and_writeable
                 ~then_:(Account_id.Checked.public_key receiver)
                 ~else_:account.public_key
             and token_id =
               Token_id.Checked.if_ is_empty_and_writeable ~then_:token
                 ~else_:account.token_id
             and token_owner =
               Boolean.if_ is_empty_and_writeable ~then_:creating_new_token
                 ~else_:account.token_permissions.token_owner
             and token_locked =
               Boolean.if_ is_empty_and_writeable
                 ~then_:payload.body.token_locked
                 ~else_:account.token_permissions.token_locked
             in
             { Account.Poly.balance
             ; public_key
             ; token_id
             ; token_permissions =
                 { Token_permissions.token_owner; token_locked }
             ; token_symbol = account.token_symbol
             ; nonce = account.nonce
             ; receipt_chain_hash = account.receipt_chain_hash
             ; delegate
             ; voting_for = account.voting_for
             ; timing = account.timing
             ; permissions = account.permissions
             ; snapp = account.snapp
             ; snapp_uri = account.snapp_uri
             }))
    in
    let%bind user_command_fails =
      Boolean.(!receiver_overflow ||| user_command_fails)
    in
    let%bind fee_payer_is_source = Account_id.Checked.equal fee_payer source in
    let%bind root_after_source_update =
      [%with_label "Update source"]
        (Frozen_ledger_hash.modify_account_send
           ~depth:constraint_constants.ledger_depth
           ~is_writeable:
             (* [modify_account_send] does this failure check for us. *)
             user_command_failure.source_not_present root_after_receiver_update
           source ~f:(fun ~is_empty_and_writeable account ->
             (* this account is:
                - the source for payments
                - the delegator for stake delegation
                - the token owner for account creation
                - the token owner for token minting
                - the fee-receiver for a coinbase
                - the second receiver for a fee transfer
             *)
             let%bind () =
               [%with_label "Check source presence failure matches predicted"]
                 (Boolean.Assert.( = ) is_empty_and_writeable
                    user_command_failure.source_not_present)
             in
             let%bind () =
               [%with_label
                 "Check source failure cases do not apply when fee-payer is \
                  source"]
                 (let num_failures =
                    let open Field.Var in
                    add
                      (user_command_failure.source_insufficient_balance :> t)
                      (user_command_failure.source_bad_timing :> t)
                  in
                  let not_fee_payer_is_source =
                    (Boolean.not fee_payer_is_source :> Field.Var.t)
                  in
                  (* Equivalent to:
                     if fee_payer_is_source then
                       num_failures = 0
                     else
                       num_failures = num_failures
                  *)
                  assert_r1cs not_fee_payer_is_source num_failures num_failures)
             in
             let%bind amount =
               (* Only payments should affect the balance at this stage. *)
               if_ is_payment ~typ:Amount.typ ~then_:payload.body.amount
                 ~else_:Amount.(var_of_t zero)
             in
             let txn_global_slot = current_global_slot in
             let%bind `Min_balance _, timing =
               [%with_label "Check source timing"]
                 (let balance_check ok =
                    [%with_label
                      "Check source balance failure matches predicted"]
                      (Boolean.Assert.( = ) ok
                         (Boolean.not
                            user_command_failure.source_insufficient_balance))
                  in
                  let timed_balance_check ok =
                    [%with_label
                      "Check source timed balance failure matches predicted"]
                      (let%bind not_ok =
                         Boolean.(
                           (not ok)
                           &&& not
                                 user_command_failure
                                   .source_insufficient_balance)
                       in
                       Boolean.Assert.( = ) not_ok
                         user_command_failure.source_bad_timing)
                  in
                  check_timing ~balance_check ~timed_balance_check ~account
                    ~txn_amount:amount ~txn_global_slot)
             in
             let%bind balance, `Underflow underflow =
               Balance.Checked.sub_amount_flagged account.balance amount
             in
             let%bind () =
               (* TODO: Remove the redundancy in balance calculation between
                  here and [check_timing].
               *)
               [%with_label "Check source balance failure matches predicted"]
                 (Boolean.Assert.( = ) underflow
                    user_command_failure.source_insufficient_balance)
             in
             let%bind () =
               [%with_label "Check not_token_owner failure matches predicted"]
                 (let%bind token_owner_ok =
                    let%bind command_needs_token_owner =
                      Boolean.(is_create_account ||| is_mint_tokens)
                    in
                    Boolean.(
                      any
                        [ account.token_permissions.token_owner
                        ; token_default
                        ; not command_needs_token_owner
                        ])
                  in
                  Boolean.(
                    Assert.( = ) (not token_owner_ok)
                      user_command_failure.not_token_owner))
             in
             let%bind () =
               [%with_label "Check that token_auth failure matches predicted"]
                 (let%bind token_auth_needed =
                    Field.Checked.equal
                      (payload.body.token_locked :> Field.Var.t)
                      (account.token_permissions.token_locked :> Field.Var.t)
                    >>| Boolean.not
                  in
                  let%bind token_auth_failed =
                    Boolean.(
                      all
                        [ token_auth_needed
                        ; not token_default
                        ; is_create_account
                        ; not creating_new_token
                        ; not predicate_result
                        ])
                  in
                  Boolean.Assert.( = ) token_auth_failed
                    user_command_failure.token_auth)
             in
             let%map delegate =
               Public_key.Compressed.Checked.if_ is_stake_delegation
                 ~then_:(Account_id.Checked.public_key receiver)
                 ~else_:account.delegate
             in
             (* NOTE: Technically we update the account here even in the case
                of [user_command_fails], but we throw the resulting hash away
                in [final_root] below, so it shouldn't matter.
             *)
             { Account.Poly.balance
             ; public_key = account.public_key
             ; token_id = account.token_id
             ; token_permissions = account.token_permissions
             ; token_symbol = account.token_symbol
             ; nonce = account.nonce
             ; receipt_chain_hash = account.receipt_chain_hash
             ; delegate
             ; voting_for = account.voting_for
             ; timing
             ; permissions = account.permissions
             ; snapp = account.snapp
             ; snapp_uri = account.snapp_uri
             }))
    in
    let%bind fee_excess =
      (* - payments:         payload.common.fee
         - stake delegation: payload.common.fee
         - account creation: payload.common.fee
         - token minting:    payload.common.fee
         - coinbase:         0 (fee already paid above)
         - fee transfer:     - payload.body.amount - payload.common.fee
      *)
      let open Amount in
      chain Signed.Checked.if_ is_coinbase
        ~then_:(return (Signed.Checked.of_unsigned (var_of_t zero)))
        ~else_:
          (let user_command_excess =
             Signed.Checked.of_unsigned (Checked.of_fee payload.common.fee)
           in
           let%bind fee_transfer_excess, fee_transfer_excess_overflowed =
             let%map magnitude, `Overflow overflowed =
               Checked.(
                 add_flagged payload.body.amount (of_fee payload.common.fee))
             in
             (Signed.create ~magnitude ~sgn:Sgn.Checked.neg, overflowed)
           in
           let%bind () =
             (* TODO: Reject this in txn pool before fees-in-tokens. *)
             [%with_label "Fee excess does not overflow"]
               Boolean.(
                 Assert.any
                   [ not is_fee_transfer; not fee_transfer_excess_overflowed ])
           in
           Signed.Checked.if_ is_fee_transfer ~then_:fee_transfer_excess
             ~else_:user_command_excess)
    in
    let%bind supply_increase =
      Amount.Checked.if_ is_coinbase ~then_:payload.body.amount
        ~else_:Amount.(var_of_t zero)
    in
    let%map final_root =
      (* Ensure that only the fee-payer was charged if this was an invalid user
         command.
      *)
      Frozen_ledger_hash.if_ user_command_fails
        ~then_:root_after_fee_payer_update ~else_:root_after_source_update
    in
    (final_root, fee_excess, supply_increase, next_available_token_after)

  (* Someday:
     write the following soundness tests:
     - apply a transaction where the signature is incorrect
     - apply a transaction where the sender does not have enough money in their account
     - apply a transaction and stuff in the wrong target hash
  *)

  (* spec for [main statement]:
     constraints pass iff there exists
        t : Tagged_transaction.t
     such that
      - applying [t] to ledger with merkle hash [l1] results in ledger with merkle hash [l2].
      - applying [t] to [pc.source] with results in pending coinbase stack [pc.target]
      - t has fee excess equal to [fee_excess]
      - t has supply increase equal to [supply_increase]
     where statement includes
        l1 : Frozen_ledger_hash.t,
        l2 : Frozen_ledger_hash.t,
        fee_excess : Amount.Signed.t,
        supply_increase : Amount.t
        pc: Pending_coinbase_stack_state.t
  *)
  let%snarkydef main ~constraint_constants
      (statement : Statement.With_sok.Checked.t) =
    let%bind () = dummy_constraints () in
    let%bind (module Shifted) = Tick.Inner_curve.Checked.Shifted.create () in
    let%bind t =
      with_label __LOC__
        (exists Transaction_union.typ ~request:(As_prover.return Transaction))
    in
    let%bind pending_coinbase_init =
      exists Pending_coinbase.Stack.typ ~request:(As_prover.return Init_stack)
    in
    let%bind state_body =
      exists
        (Mina_state.Protocol_state.Body.typ ~constraint_constants)
        ~request:(As_prover.return State_body)
    in
    let%bind root_after, fee_excess, supply_increase, next_available_token_after
        =
      apply_tagged_transaction ~constraint_constants
        (module Shifted)
        statement.source.ledger pending_coinbase_init
        statement.source.pending_coinbase_stack
        statement.target.pending_coinbase_stack
        statement.source.next_available_token state_body t
    in
    let%bind fee_excess =
      (* Use the default token for the fee excess if it is zero.
         This matches the behaviour of [Fee_excess.rebalance], which allows
         [verify_complete_merge] to verify a proof without knowledge of the
         particular fee tokens used.
      *)
      let%bind fee_excess_zero =
        Amount.equal_var fee_excess.magnitude Amount.(var_of_t zero)
      in
      let%map fee_token_l =
        Token_id.Checked.if_ fee_excess_zero
          ~then_:Token_id.(var_of_t default)
          ~else_:t.payload.common.fee_token
      in
      { Fee_excess.fee_token_l
      ; fee_excess_l = Signed_poly.map ~f:Amount.Checked.to_fee fee_excess
      ; fee_token_r = Token_id.(var_of_t default)
      ; fee_excess_r = Fee.Signed.(Checked.constant zero)
      }
    in
    let%bind () =
      make_checked (fun () ->
          Local_state.Checked.assert_equal statement.source.local_state
            statement.target.local_state)
    in
    Checked.all_unit
      [ Frozen_ledger_hash.assert_equal root_after statement.target.ledger
      ; Currency.Amount.Checked.assert_equal supply_increase
          statement.supply_increase
      ; Fee_excess.assert_equal_checked fee_excess statement.fee_excess
      ; Token_id.Checked.Assert.equal next_available_token_after
          statement.target.next_available_token
      ]

  let rule ~constraint_constants : _ Pickles.Inductive_rule.t =
    { identifier = "transaction"
    ; prevs = []
    ; main =
        (fun [] x ->
          Run.run_checked (main ~constraint_constants x) ;
          [])
    ; main_value = (fun [] _ -> [])
    }

  let transaction_union_handler handler (transaction : Transaction_union.t)
      (state_body : Mina_state.Protocol_state.Body.Value.t)
      (init_stack : Pending_coinbase.Stack.t) :
      Snarky_backendless.Request.request -> _ =
   fun (With { request; respond } as r) ->
    match request with
    | Transaction ->
        respond (Provide transaction)
    | State_body ->
        respond (Provide state_body)
    | Init_stack ->
        respond (Provide init_stack)
    | _ ->
        handler r
end

module Transition_data = struct
  type t =
    { proof : Proof_type.t
    ; supply_increase : Amount.t
    ; fee_excess : Fee_excess.t
    ; sok_digest : Sok_message.Digest.t
    ; pending_coinbase_stack_state : Pending_coinbase_stack_state.t
    }
  [@@deriving fields]
end

module Merge = struct
  open Tick

  (* spec for [main top_hash]:
     constraints pass iff
     there exist digest, s1, s3, fee_excess, supply_increase pending_coinbase_stack12.source, pending_coinbase_stack23.target, tock_vk such that
     H(digest,s1, s3, pending_coinbase_stack12.source, pending_coinbase_stack23.target, fee_excess, supply_increase, tock_vk) = top_hash,
     verify_transition tock_vk _ s1 s2 pending_coinbase_stack12.source, pending_coinbase_stack12.target is true
     verify_transition tock_vk _ s2 s3 pending_coinbase_stack23.source, pending_coinbase_stack23.target is true
  *)
  let%snarkydef main
      ([ s1; s2 ] :
        (Statement.With_sok.var * (Statement.With_sok.var * _))
        Pickles_types.Hlist.HlistId.t) (s : Statement.With_sok.Checked.t) =
    let%bind fee_excess =
      Fee_excess.combine_checked s1.Statement.fee_excess s2.Statement.fee_excess
    in
    let%bind () =
      with_label __LOC__
        (let%bind valid_pending_coinbase_stack_transition =
           Pending_coinbase.Stack.Checked.check_merge
             ~transition1:
               ( s1.source.pending_coinbase_stack
               , s1.target.pending_coinbase_stack )
             ~transition2:
               ( s2.source.pending_coinbase_stack
               , s2.target.pending_coinbase_stack )
         in
         Boolean.Assert.is_true valid_pending_coinbase_stack_transition)
    in
    let%bind supply_increase =
      Amount.Checked.add s1.supply_increase s2.supply_increase
    in
    let%bind () =
      make_checked (fun () ->
          Local_state.Checked.assert_equal s.source.local_state
            s1.source.local_state ;
          Local_state.Checked.assert_equal s.target.local_state
            s2.target.local_state)
    in
    Checked.all_unit
      [ Fee_excess.assert_equal_checked fee_excess s.fee_excess
      ; Amount.Checked.assert_equal supply_increase s.supply_increase
      ; Frozen_ledger_hash.assert_equal s.source.ledger s1.source.ledger
      ; Frozen_ledger_hash.assert_equal s1.target.ledger s2.source.ledger
      ; Frozen_ledger_hash.assert_equal s2.target.ledger s.target.ledger
      ; Token_id.Checked.Assert.equal s.source.next_available_token
          s1.source.next_available_token
      ; Token_id.Checked.Assert.equal s1.target.next_available_token
          s2.source.next_available_token
      ; Token_id.Checked.Assert.equal s2.target.next_available_token
          s.target.next_available_token
      ]

  let rule ~proof_level self : _ Pickles.Inductive_rule.t =
    let prev_should_verify =
      match proof_level with
      | Genesis_constants.Proof_level.Full ->
          true
      | _ ->
          false
    in
    let b = Boolean.var_of_value prev_should_verify in
    { identifier = "merge"
    ; prevs = [ self; self ]
    ; main =
        (fun ps x ->
          Run.run_checked (main ps x) ;
          [ b; b ])
    ; main_value = (fun _ _ -> [ prev_should_verify; prev_should_verify ])
    }
end

open Pickles_types

type tag =
  ( Statement.With_sok.Checked.t
  , Statement.With_sok.t
  , Nat.N2.n
  , Nat.N6.n )
  Pickles.Tag.t

let time lab f =
  let start = Time.now () in
  let x = f () in
  let stop = Time.now () in
  printf "%s: %s\n%!" lab (Time.Span.to_string_hum (Time.diff stop start)) ;
  x

let system ~proof_level ~constraint_constants =
  time "Transaction_snark.system" (fun () ->
      Pickles.compile ~cache:Cache_dir.cache
        (module Statement.With_sok.Checked)
        (module Statement.With_sok)
        ~typ:Statement.With_sok.typ
        ~branches:(module Nat.N6)
        ~max_branching:(module Nat.N2)
        ~name:"transaction-snark"
        ~constraint_constants:
          (Genesis_constants.Constraint_constants.to_snark_keys_header
             constraint_constants)
        ~choices:(fun ~self ->
          let parties x =
            Base.Parties_snark.rule ~constraint_constants ~proof_level x
          in
          [ Base.rule ~constraint_constants
          ; Merge.rule ~proof_level self
          ; parties Opt_signed_unsigned
          ; parties Opt_signed_opt_signed
          ; parties Opt_signed
          ; parties Proved
          ]))

module Verification = struct
  module type S = sig
    val tag : tag

    val verify : (t * Sok_message.t) list -> bool Async.Deferred.t

    val id : Pickles.Verification_key.Id.t Lazy.t

    val verification_key : Pickles.Verification_key.t Lazy.t

    val verify_against_digest : t -> bool Async.Deferred.t

    val constraint_system_digests : (string * Md5_lib.t) list Lazy.t
  end
end

module type S = sig
  include Verification.S

  val cache_handle : Pickles.Cache_handle.t

  val of_non_parties_transaction :
       statement:Statement.With_sok.t
    -> init_stack:Pending_coinbase.Stack.t
    -> Transaction.Valid.t Transaction_protocol_state.t
    -> Tick.Handler.t
    -> t Async.Deferred.t

  val of_user_command :
       statement:Statement.With_sok.t
    -> init_stack:Pending_coinbase.Stack.t
    -> Signed_command.With_valid_signature.t Transaction_protocol_state.t
    -> Tick.Handler.t
    -> t Async.Deferred.t

  val of_fee_transfer :
       statement:Statement.With_sok.t
    -> init_stack:Pending_coinbase.Stack.t
    -> Fee_transfer.t Transaction_protocol_state.t
    -> Tick.Handler.t
    -> t Async.Deferred.t

  val of_parties_segment_exn :
       statement:Statement.With_sok.t
    -> witness:Parties_segment.Witness.t
    -> t Async.Deferred.t

  val merge :
    t -> t -> sok_digest:Sok_message.Digest.t -> t Async.Deferred.Or_error.t
end

let check_transaction_union ?(preeval = false) ~constraint_constants sok_message
    source target init_stack pending_coinbase_stack_state
    next_available_token_before next_available_token_after transaction
    state_body handler =
  if preeval then failwith "preeval currently disabled" ;
  let sok_digest = Sok_message.digest sok_message in
  let handler =
    Base.transaction_union_handler handler transaction state_body init_stack
  in
  let statement : Statement.With_sok.t =
    Statement.Poly.to_latest
      { source
      ; target
      ; supply_increase = Transaction_union.supply_increase transaction
      ; pending_coinbase_stack_state
      ; fee_excess = Transaction_union.fee_excess transaction
      ; next_available_token_before
      ; next_available_token_after
      ; sok_digest
      }
  in
  let open Tick in
  ignore
    ( Or_error.ok_exn
        (run_and_check
           (handle
              (Checked.map ~f:As_prover.return
                 (let open Checked in
                 exists Statement.With_sok.typ
                   ~compute:(As_prover.return statement)
                 >>= Base.main ~constraint_constants))
              handler)
           ())
      : unit * unit )

let check_transaction ?preeval ~constraint_constants ~sok_message ~source
    ~target ~init_stack ~pending_coinbase_stack_state
    ~next_available_token_before ~next_available_token_after ~snapp_account1:_
    ~snapp_account2:_
    (transaction_in_block : Transaction.Valid.t Transaction_protocol_state.t)
    handler =
  let transaction =
    Transaction_protocol_state.transaction transaction_in_block
  in
  let state_body = Transaction_protocol_state.block_data transaction_in_block in
  match to_preunion (transaction :> Transaction.t) with
  | `Parties _ ->
      failwith "TODO"
  | `Transaction t ->
      check_transaction_union ?preeval ~constraint_constants sok_message source
        target init_stack pending_coinbase_stack_state
        next_available_token_before next_available_token_after
        (Transaction_union.of_transaction t)
        state_body handler

let check_user_command ~constraint_constants ~sok_message ~source ~target
    ~init_stack ~pending_coinbase_stack_state ~next_available_token_before
    ~next_available_token_after t_in_block handler =
  let user_command = Transaction_protocol_state.transaction t_in_block in
  check_transaction ~constraint_constants ~sok_message ~source ~target
    ~init_stack ~pending_coinbase_stack_state ~next_available_token_before
    ~next_available_token_after ~snapp_account1:None ~snapp_account2:None
    { t_in_block with transaction = Command (Signed_command user_command) }
    handler

let generate_transaction_union_witness ?(preeval = false) ~constraint_constants
    sok_message source target transaction_in_block init_stack
    next_available_token_before next_available_token_after
    pending_coinbase_stack_state handler =
  if preeval then failwith "preeval currently disabled" ;
  let transaction =
    Transaction_protocol_state.transaction transaction_in_block
  in
  let state_body = Transaction_protocol_state.block_data transaction_in_block in
  let sok_digest = Sok_message.digest sok_message in
  let handler =
    Base.transaction_union_handler handler transaction state_body init_stack
  in
  let statement : Statement.With_sok.t =
    Statement.Poly.to_latest
      { source
      ; target
      ; supply_increase = Transaction_union.supply_increase transaction
      ; pending_coinbase_stack_state
      ; fee_excess = Transaction_union.fee_excess transaction
      ; next_available_token_before
      ; next_available_token_after
      ; sok_digest
      }
  in
  let open Tick in
  let main x = handle (Base.main ~constraint_constants x) handler in
  generate_auxiliary_input [ Statement.With_sok.typ ] () main statement

let generate_transaction_witness ?preeval ~constraint_constants ~sok_message
    ~source ~target ~init_stack ~pending_coinbase_stack_state
    ~next_available_token_before ~next_available_token_after ~snapp_account1:_
    ~snapp_account2:_
    (transaction_in_block : Transaction.Valid.t Transaction_protocol_state.t)
    handler =
  match
    to_preunion
      ( Transaction_protocol_state.transaction transaction_in_block
        :> Transaction.t )
  with
  | `Parties _ ->
      failwith "TODO"
  | `Transaction t ->
      generate_transaction_union_witness ?preeval ~constraint_constants
        sok_message source target
        { transaction_in_block with
          transaction = Transaction_union.of_transaction t
        }
        init_stack next_available_token_before next_available_token_after
        pending_coinbase_stack_state handler

let verify (ts : (t * _) list) ~key =
  if
    List.for_all ts ~f:(fun ({ statement; _ }, message) ->
        Sok_message.Digest.equal
          (Sok_message.digest message)
          statement.sok_digest)
  then
    Pickles.verify
      (module Nat.N2)
      (module Statement.With_sok)
      key
      (List.map ts ~f:(fun ({ statement; proof }, _) -> (statement, proof)))
  else Async.return false

let constraint_system_digests ~constraint_constants () =
  let digest = Tick.R1CS_constraint_system.digest in
  [ ( "transaction-merge"
    , digest
        Merge.(
          Tick.constraint_system ~exposing:[ Statement.With_sok.typ ] (fun x ->
              let open Tick in
              let%bind x1 = exists Statement.With_sok.typ in
              let%bind x2 = exists Statement.With_sok.typ in
              main [ x1; x2 ] x)) )
  ; ( "transaction-base"
    , digest
        Base.(
          Tick.constraint_system ~exposing:[ Statement.With_sok.typ ]
            (main ~constraint_constants)) )
  ]

(** [group_by_parties_rev partiess stmtss] identifies before/after pairs of
    statements, corresponding to parties in [partiess] which minimize the
    number of snark proofs needed to prove all of the parties.

    This function is intended to take the parties from multiple transactions as
    its input, which may be converted from a [Parties.t list] using
    [List.map ~f:Parties.parties]. The [stmtss] argument should be a list of
    the same length, with 1 more state than the number of parties for each
    transaction.

    For example, two transactions made up of parties [[p1; p2; p3]] and
    [[p4; p5]] should have the statements [[[s0; s1; s2; s3]; [s3; s4; s5]]],
    where each [s_n] is the state after applying [p_n] on top of [s_{n-1}], and
    where [s0] is the initial state before any of the transactions have been
    applied.

    Each pair is also identified with one of [`Same], [`New], or [`Two_new],
    indicating that the next one ([`New]) or next two ([`Two_new]) [Parties.t]s
    will need to be passed as part of the snark witness while applying that
    pair.
*)
let group_by_parties_rev partiess stmtss =
  let rec group_by_parties_rev partiess stmtss acc =
    match (partiess, stmtss) with
    | ([] | [ [] ]), [ _ ] ->
        (* We've associated statements with all given parties. *)
        acc
    | [ [ { Party.authorization = a1; _ } ] ], [ [ before; after ] ] ->
        (* There are no later parties to pair this one with. Prove it on its
           own.
        *)
        (`Same, Parties_segment.Basic.of_controls [ a1 ], before, after) :: acc
    | [ []; [ { Party.authorization = a1; _ } ] ], [ [ _ ]; [ before; after ] ]
      ->
        (* This party is part of a new transaction, and there are no later
           parties to pair it with. Prove it on its own.
        *)
        (`New, Parties_segment.Basic.of_controls [ a1 ], before, after) :: acc
    | ( ({ Party.authorization = Proof _ as a1; _ } :: parties) :: partiess
      , (before :: (after :: _ as stmts)) :: stmtss ) ->
        (* This party contains a proof, don't pair it with other parties. *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`Same, Parties_segment.Basic.of_controls [ a1 ], before, after)
          :: acc )
    | ( [] :: ({ Party.authorization = Proof _ as a1; _ } :: parties) :: partiess
      , [ _ ] :: (before :: (after :: _ as stmts)) :: stmtss ) ->
        (* This party is part of a new transaction, and contains a proof, don't
           pair it with other parties.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`New, Parties_segment.Basic.of_controls [ a1 ], before, after)
          :: acc )
    | ( ({ Party.authorization = a1; _ }
        :: ({ Party.authorization = Proof _ as a2; _ } :: _ as parties))
        :: partiess
      , (before :: (after :: _ as stmts)) :: stmtss ) ->
        (* The next party contains a proof, don't pair it with this party. *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`Same, Parties_segment.Basic.of_controls [ a1; a2 ], before, after)
          :: acc )
    | ( ({ Party.authorization = a1; _ } :: ([] as parties))
        :: (({ Party.authorization = Proof _ as a2; _ } :: _) :: _ as partiess)
      , (before :: (after :: _ as stmts)) :: stmtss ) ->
        (* The next party is in the next transaction and contains a proof,
           don't pair it with this party.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`Same, Parties_segment.Basic.of_controls [ a1; a2 ], before, after)
          :: acc )
    | ( ({ Party.authorization = a1; _ }
        :: { Party.authorization = a2; _ } :: parties)
        :: partiess
      , (before :: _ :: (after :: _ as stmts)) :: stmtss ) ->
        (* The next two parties do not contain proofs, and are within the same
           transaction. Pair them.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`Same, Parties_segment.Basic.of_controls [ a1; a2 ], before, after)
          :: acc )
    | ( []
        :: ({ Party.authorization = a1; _ }
           :: { Party.authorization = a2; _ } :: parties)
           :: partiess
      , [ _ ] :: (before :: _ :: (after :: _ as stmts)) :: stmtss ) ->
        (* The next two parties do not contain proofs, and are within the same
           new transaction. Pair them.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`New, Parties_segment.Basic.of_controls [ a1; a2 ], before, after)
          :: acc )
    | ( [ { Party.authorization = a1; _ } ]
        :: ({ Party.authorization = a2; _ } :: parties) :: partiess
      , (before :: _after1) :: (_before2 :: (after :: _ as stmts)) :: stmtss )
      ->
        (* The next two parties do not contain proofs, and the second is within
           a new transaction. Pair them.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( (`New, Parties_segment.Basic.of_controls [ a1; a2 ], before, after)
          :: acc )
    | ( []
        :: [ { Party.authorization = a1; _ } ]
           :: ({ Party.authorization = a2; _ } :: parties) :: partiess
      , [ _ ]
        :: [ before; _after1 ] :: (_before2 :: (after :: _ as stmts)) :: stmtss
      ) ->
        (* The next two parties do not contain proofs, the first is within a
           new transaction, and the second is within another new transaction.
           Pair them.
        *)
        group_by_parties_rev (parties :: partiess) (stmts :: stmtss)
          ( ( `Two_new
            , Parties_segment.Basic.of_controls [ a1; a2 ]
            , before
            , after )
          :: acc )
    | [ [ { Party.authorization = a1; _ } ] ], (before :: after :: _) :: _ ->
        (* This party is the final party given. Prove it on its own. *)
        (`Same, Parties_segment.Basic.of_controls [ a1 ], before, after) :: acc
    | ( [] :: [ { Party.authorization = a1; _ } ] :: [] :: _
      , [ _ ] :: (before :: after :: _) :: _ ) ->
        (* This party is the final party given, in a new transaction. Prove it
           on its own.
        *)
        (`New, Parties_segment.Basic.of_controls [ a1 ], before, after) :: acc
    | _, [] ->
        failwith "group_by_parties_rev: No statements remaining"
    | ([] | [ [] ]), _ ->
        failwith "group_by_parties_rev: Unmatched statements remaining"
    | [] :: _, [] :: _ ->
        failwith
          "group_by_parties_rev: No final statement for current transaction"
    | [] :: _, (_ :: _ :: _) :: _ ->
        failwith
          "group_by_parties_rev: Unmatched statements for current transaction"
    | [] :: [ _ ] :: _, [ _ ] :: (_ :: _ :: _ :: _) :: _ ->
        failwith
          "group_by_parties_rev: Unmatched statements for next transaction"
    | [ []; [ _ ] ], [ _ ] :: [ _; _ ] :: _ :: _ ->
        failwith
          "group_by_parties_rev: Unmatched statements after next transaction"
    | (_ :: _) :: _, ([] | [ _ ]) :: _ | (_ :: _ :: _) :: _, [ _; _ ] :: _ ->
        failwith
          "group_by_parties_rev: Too few statements remaining for the current \
           transaction"
    | ([] | [ _ ]) :: [] :: _, _ ->
        failwith "group_by_parties_rev: The next transaction has no parties"
    | [] :: (_ :: _) :: _, _ :: ([] | [ _ ]) :: _
    | [] :: (_ :: _ :: _) :: _, _ :: [ _; _ ] :: _ ->
        failwith
          "group_by_parties_rev: Too few statements remaining for the next \
           transaction"
    | [ _ ] :: (_ :: _) :: _, _ :: ([] | [ _ ]) :: _ ->
        failwith
          "group_by_parties_rev: Too few statements remaining for the next \
           transaction"
    | [] :: [ _ ] :: (_ :: _) :: _, _ :: _ :: ([] | [ _ ]) :: _ ->
        failwith
          "group_by_parties_rev: Too few statements remaining for the \
           transaction after next"
    | ([] | [ _ ]) :: (_ :: _) :: _, [ _ ] ->
        failwith
          "group_by_parties_rev: No statements given for the next transaction"
    | [] :: [ _ ] :: (_ :: _) :: _, [ _; (_ :: _ :: _) ] ->
        failwith
          "group_by_parties_rev: No statements given for transaction after next"
  in
  group_by_parties_rev partiess stmtss []

module Make (Inputs : sig
  val constraint_constants : Genesis_constants.Constraint_constants.t

  val proof_level : Genesis_constants.Proof_level.t
end) =
struct
  open Inputs

  let ( tag
      , cache_handle
      , p
      , Pickles.Provers.
          [ base
          ; merge
          ; opt_signed_unsigned
          ; opt_signed_opt_signed
          ; opt_signed
          ; proved
          ] ) =
    system ~proof_level ~constraint_constants

  module Proof = (val p)

  let id = Proof.id

  let verification_key = Proof.verification_key

  let verify_against_digest { statement; proof } =
    Proof.verify [ (statement, proof) ]

  let verify ts =
    if
      List.for_all ts ~f:(fun (p, m) ->
          Sok_message.Digest.equal (Sok_message.digest m) p.statement.sok_digest)
    then
      Proof.verify
        (List.map ts ~f:(fun ({ statement; proof }, _) -> (statement, proof)))
    else Async.return false

  let of_parties_segment_exn ~statement ~witness : t Async.Deferred.t =
    Base.Parties_snark.witness := Some witness ;
    let types =
      List.map
        (Parties.Party_or_stack.to_parties_list
           witness.local_state_init.parties) ~f:(fun (p, _) ->
          Control.tag p.authorization)
      @ List.concat_map witness.start_parties ~f:(fun s ->
            Control.Tag.Signature
            :: List.map s.parties.other_parties ~f:(fun p ->
                   Control.tag p.authorization))
    in
    let type_ : Parties_segment.Basic.t =
      match types with
      | [ Signature ] ->
          Opt_signed
      | [ None_given ] ->
          Opt_signed
      | [ Proof ] ->
          Proved
      | [ Signature; None_given ] | [ None_given; None_given ] ->
          Opt_signed_unsigned
      | [ Signature; Signature ] | [ None_given; Signature ] ->
          Opt_signed_opt_signed
      | _ ->
          failwithf
            !"Sequence of control types not supported as a basic sequence: \
              %{sexp: Control.Tag.t list}"
            types ()
    in
    let res =
      match type_ with
      | Opt_signed ->
          opt_signed [] statement
      | Opt_signed_unsigned ->
          opt_signed_unsigned [] statement
      | Opt_signed_opt_signed ->
          opt_signed_opt_signed [] statement
      | Proved ->
          let proofs =
            let party_proof (p : Party.t) =
              match p.authorization with
              | Proof p ->
                  Some p
              | Signature _ | None_given ->
                  None
            in
            let open Option.Let_syntax in
            List.filter_map
              (Parties.Party_or_stack.to_parties_with_hashes_list
                 witness.local_state_init.parties)
              ~f:(fun ((p, ()), at_party) ->
                let%map pi = party_proof p in
                ( { Snapp_statement.Poly.transaction =
                      witness.local_state_init.transaction_commitment
                  ; at_party
                  }
                , pi ))
            @ List.concat_map witness.start_parties ~f:(fun s ->
                  (* TODO: This is unnecessary re-computation of the statements which are also computed in
                     the circuit. It would be better to use the values computed inside the circuit, but it
                     was involved to change the pickles API to allow it. *)
                  let other_parties, transaction =
                    let ps =
                      Parties.Party_or_stack.With_hashes.of_parties_list
                        (List.map ~f:(fun p -> (p, ())) s.parties.other_parties)
                    in
                    ( ps
                    , Parties.Transaction_commitment.create
                        ~other_parties_hash:
                          (Parties.Party_or_stack.stack_hash ps)
                        ~protocol_state_predicate_hash:
                          (Snapp_predicate.Protocol_state.digest
                             s.protocol_state_predicate) )
                  in
                  List.filter_map
                    (Parties.Party_or_stack.to_parties_with_hashes_list
                       other_parties) ~f:(fun ((p, ()), at_party) ->
                      let%map pi = party_proof p in
                      ({ Snapp_statement.Poly.transaction; at_party }, pi)))
          in
          proved
            ( match proofs with
            | [ p ] ->
                (* TODO: We should not have to pass the statement in here. *)
                [ p ]
            | [] | _ :: _ :: _ ->
                failwith "of_parties_segment: Expected exactly one proof" )
            statement
    in
    Base.Parties_snark.witness := None ;
    let open Async in
    let%map proof = res in
    { proof; statement }

  let of_transaction_union ~statement ~init_stack transaction state_body handler
      =
    let open Async in
    let%map proof =
      base []
        ~handler:
          (Base.transaction_union_handler handler transaction state_body
             init_stack)
        statement
    in
    { statement; proof }

  let of_non_parties_transaction ~statement ~init_stack transaction_in_block
      handler =
    let transaction : Transaction.t =
      Transaction.forget
        (Transaction_protocol_state.transaction transaction_in_block)
    in
    let state_body =
      Transaction_protocol_state.block_data transaction_in_block
    in
    match to_preunion transaction with
    | `Parties _ ->
        failwith "TODO"
    | `Transaction t ->
        of_transaction_union ~statement ~init_stack
          (Transaction_union.of_transaction t)
          state_body handler

  let of_user_command ~statement ~init_stack user_command_in_block handler =
    of_non_parties_transaction ~statement ~init_stack
      { user_command_in_block with
        transaction =
          Command
            (Signed_command
               (Transaction_protocol_state.transaction user_command_in_block))
      }
      handler

  let of_fee_transfer ~statement ~init_stack transfer_in_block handler =
    of_non_parties_transaction ~statement ~init_stack
      { transfer_in_block with
        transaction =
          Fee_transfer
            (Transaction_protocol_state.transaction transfer_in_block)
      }
      handler

  let merge ({ statement = t12; _ } as x12) ({ statement = t23; _ } as x23)
      ~sok_digest =
    let open Async.Deferred.Or_error.Let_syntax in
    let%bind s = Async.return (Statement.merge t12 t23) in
    let s = { s with sok_digest } in
    let open Async in
    let%map proof =
      merge [ (x12.statement, x12.proof); (x23.statement, x23.proof) ] s
    in
    Ok { statement = s; proof }

  let constraint_system_digests =
    lazy (constraint_system_digests ~constraint_constants ())
end

let%test_module "transaction_snark" =
  ( module struct
    let constraint_constants =
      Genesis_constants.Constraint_constants.for_unit_tests

    let genesis_constants = Genesis_constants.for_unit_tests

    let proof_level = Genesis_constants.Proof_level.for_unit_tests

    let consensus_constants =
      Consensus.Constants.create ~constraint_constants
        ~protocol_constants:genesis_constants.protocol

    (* For tests let's just monkey patch ledger and sparse ledger to freeze their
     * ledger_hashes. The nominal type is just so we don't mix this up in our
     * real code. *)
    module Ledger = struct
      include Ledger

      let merkle_root t = Frozen_ledger_hash.of_ledger_hash @@ merkle_root t

      let merkle_root_after_parties_exn t ~txn_state_view txn =
        let hash, `Next_available_token tid =
          merkle_root_after_parties_exn ~constraint_constants ~txn_state_view t
            txn
        in
        (Frozen_ledger_hash.of_ledger_hash hash, `Next_available_token tid)

      let merkle_root_after_user_command_exn t ~txn_global_slot txn =
        let hash, `Next_available_token tid =
          merkle_root_after_user_command_exn ~constraint_constants
            ~txn_global_slot t txn
        in
        (Frozen_ledger_hash.of_ledger_hash hash, `Next_available_token tid)
    end

    module Sparse_ledger = struct
      include Sparse_ledger

      let merkle_root t = Frozen_ledger_hash.of_ledger_hash @@ merkle_root t
    end

    type wallet = { private_key : Private_key.t; account : Account.t }

    let ledger_depth = constraint_constants.ledger_depth

    let random_wallets ?(n = min (Int.pow 2 ledger_depth) (1 lsl 10)) () =
      let random_wallet () : wallet =
        let private_key = Private_key.create () in
        let public_key =
          Public_key.compress (Public_key.of_private_key_exn private_key)
        in
        let account_id = Account_id.create public_key Token_id.default in
        { private_key
        ; account =
            Account.create account_id
              (Balance.of_int ((50 + Random.int 100) * 1_000_000_000))
        }
      in
      Array.init n ~f:(fun _ -> random_wallet ())

    let user_command ~fee_payer ~source_pk ~receiver_pk ~fee_token ~token amt
        fee nonce memo =
      let payload : Signed_command.Payload.t =
        Signed_command.Payload.create ~fee ~fee_token
          ~fee_payer_pk:(Account.public_key fee_payer.account)
          ~nonce ~memo ~valid_until:None
          ~body:
            (Payment
               { source_pk
               ; receiver_pk
               ; token_id = token
               ; amount = Amount.of_int amt
               })
      in
      let signature =
        Signed_command.sign_payload fee_payer.private_key payload
      in
      Signed_command.check
        Signed_command.Poly.Stable.Latest.
          { payload
          ; signer = Public_key.of_private_key_exn fee_payer.private_key
          ; signature
          }
      |> Option.value_exn

    let user_command_with_wallet wallets ~sender:i ~receiver:j amt fee
        ~fee_token ~token nonce memo =
      let fee_payer = wallets.(i) in
      let receiver = wallets.(j) in
      user_command ~fee_payer
        ~source_pk:(Account.public_key fee_payer.account)
        ~receiver_pk:(Account.public_key receiver.account)
        ~fee_token ~token amt fee nonce memo

    include Make (struct
      let constraint_constants = constraint_constants

      let proof_level = proof_level
    end)

    let state_body =
      let compile_time_genesis =
        (*not using Precomputed_values.for_unit_test because of dependency cycle*)
        Mina_state.Genesis_protocol_state.t
          ~genesis_ledger:Genesis_ledger.(Packed.t for_unit_tests)
          ~genesis_epoch_data:Consensus.Genesis_epoch_data.for_unit_tests
          ~constraint_constants ~consensus_constants
      in
      compile_time_genesis.data |> Mina_state.Protocol_state.body

    let state_body_hash = Mina_state.Protocol_state.Body.hash state_body

    let pending_coinbase_stack_target (t : Transaction.Valid.t) state_body_hash
        stack =
      let stack_with_state =
        Pending_coinbase.Stack.(push_state state_body_hash stack)
      in
      match t with
      | Coinbase c ->
          Pending_coinbase.(Stack.push_coinbase c stack_with_state)
      | _ ->
          stack_with_state

    let check_balance pk balance ledger =
      let loc = Ledger.location_of_account ledger pk |> Option.value_exn in
      let acc = Ledger.get ledger loc |> Option.value_exn in
      [%test_eq: Balance.t] acc.balance (Balance.of_int balance)

    let of_user_command' sok_digest ledger
        (user_command : Signed_command.With_valid_signature.t) init_stack
        pending_coinbase_stack_state state_body handler =
      let source = Ledger.merkle_root ledger in
      let current_global_slot =
        Mina_state.Protocol_state.Body.consensus_state state_body
        |> Consensus.Data.Consensus_state.global_slot_since_genesis
      in
      let next_available_token_before = Ledger.next_available_token ledger in
      let target, `Next_available_token next_available_token_after =
        Ledger.merkle_root_after_user_command_exn ledger
          ~txn_global_slot:current_global_slot user_command
      in
      let user_command_in_block =
        { Transaction_protocol_state.Poly.transaction = user_command
        ; block_data = state_body
        }
      in
      Async.Thread_safe.block_on_async_exn (fun () ->
          let statement =
            let txn =
              Transaction.Command
                (User_command.Signed_command
                   (Signed_command.forget_check user_command))
            in
            Statement.Poly.to_latest
              { source
              ; target
              ; sok_digest
              ; next_available_token_before
              ; next_available_token_after
              ; fee_excess = Or_error.ok_exn (Transaction.fee_excess txn)
              ; supply_increase =
                  Or_error.ok_exn (Transaction.supply_increase txn)
              ; pending_coinbase_stack_state
              }
          in
          of_user_command ~init_stack ~statement user_command_in_block handler)

    let coinbase_test state_body ~carryforward =
      let mk_pubkey () =
        Public_key.(compress (of_private_key_exn (Private_key.create ())))
      in
      let state_body_hash = Mina_state.Protocol_state.Body.hash state_body in
      let producer = mk_pubkey () in
      let producer_id = Account_id.create producer Token_id.default in
      let receiver = mk_pubkey () in
      let receiver_id = Account_id.create receiver Token_id.default in
      let other = mk_pubkey () in
      let other_id = Account_id.create other Token_id.default in
      let pending_coinbase_init = Pending_coinbase.Stack.empty in
      let cb =
        Coinbase.create
          ~amount:(Currency.Amount.of_int 10_000_000_000)
          ~receiver
          ~fee_transfer:
            (Some
               (Coinbase.Fee_transfer.create ~receiver_pk:other
                  ~fee:constraint_constants.account_creation_fee))
        |> Or_error.ok_exn
      in
      let transaction = Transaction.Coinbase cb in
      let source_stack =
        if carryforward then
          Pending_coinbase.Stack.(
            push_state state_body_hash pending_coinbase_init)
        else pending_coinbase_init
      in
      let pending_coinbase_stack_target =
        pending_coinbase_stack_target transaction state_body_hash
          pending_coinbase_init
      in
      let txn_in_block =
        { Transaction_protocol_state.Poly.transaction; block_data = state_body }
      in
      Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
          Ledger.create_new_account_exn ledger producer_id
            (Account.create receiver_id Balance.zero) ;
          let sparse_ledger =
            Sparse_ledger.of_ledger_subset_exn ledger
              [ producer_id; receiver_id; other_id ]
          in
          let sparse_ledger_after =
            Sparse_ledger.apply_transaction_exn ~constraint_constants
              sparse_ledger
              ~txn_state_view:
                (txn_in_block.block_data |> Mina_state.Protocol_state.Body.view)
              txn_in_block.transaction
          in
          check_transaction txn_in_block
            (unstage (Sparse_ledger.handler sparse_ledger))
            ~constraint_constants
            ~sok_message:
              (Mina_base.Sok_message.create ~fee:Currency.Fee.zero
                 ~prover:Public_key.Compressed.empty)
            ~source:(Sparse_ledger.merkle_root sparse_ledger)
            ~target:(Sparse_ledger.merkle_root sparse_ledger_after)
            ~next_available_token_before:(Ledger.next_available_token ledger)
            ~next_available_token_after:
              (Sparse_ledger.next_available_token sparse_ledger_after)
            ~init_stack:pending_coinbase_init
            ~pending_coinbase_stack_state:
              { source = source_stack; target = pending_coinbase_stack_target }
            ~snapp_account1:None ~snapp_account2:None)

    let%test_unit "coinbase with new state body hash" =
      Test_util.with_randomness 123456789 (fun () ->
          coinbase_test state_body ~carryforward:false)

    let%test_unit "coinbase with carry-forward state body hash" =
      Test_util.with_randomness 123456789 (fun () ->
          coinbase_test state_body ~carryforward:true)

    let%test_unit "new_account" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets () in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              Array.iter
                (Array.sub wallets ~pos:1 ~len:(Array.length wallets - 1))
                ~f:(fun { account; private_key = _ } ->
                  Ledger.create_new_account_exn ledger
                    (Account.identifier account)
                    account) ;
              let t1 =
                user_command_with_wallet wallets ~sender:1 ~receiver:0
                  8_000_000_000
                  (Fee.of_int (Random.int 20 * 1_000_000_000))
                  ~fee_token:Token_id.default ~token:Token_id.default
                  Account.Nonce.zero
                  (Signed_command_memo.create_by_digesting_string_exn
                     (Test_util.arbitrary_string
                        ~len:Signed_command_memo.max_digestible_string_length))
              in
              let current_global_slot =
                Mina_state.Protocol_state.Body.consensus_state state_body
                |> Consensus.Data.Consensus_state.global_slot_since_genesis
              in
              let next_available_token_before =
                Ledger.next_available_token ledger
              in
              let target, `Next_available_token next_available_token_after =
                Ledger.merkle_root_after_user_command_exn ledger
                  ~txn_global_slot:current_global_slot t1
              in
              let mentioned_keys =
                Signed_command.accounts_accessed
                  ~next_available_token:next_available_token_before
                  (Signed_command.forget_check t1)
              in
              let sparse_ledger =
                Sparse_ledger.of_ledger_subset_exn ledger mentioned_keys
              in
              let sok_message =
                Sok_message.create ~fee:Fee.zero
                  ~prover:wallets.(1).account.public_key
              in
              let pending_coinbase_stack = Pending_coinbase.Stack.empty in
              let pending_coinbase_stack_target =
                pending_coinbase_stack_target (Command (Signed_command t1))
                  state_body_hash pending_coinbase_stack
              in
              let pending_coinbase_stack_state =
                { Pending_coinbase_stack_state.source = pending_coinbase_stack
                ; target = pending_coinbase_stack_target
                }
              in
              check_user_command ~constraint_constants ~sok_message
                ~source:(Ledger.merkle_root ledger)
                ~target ~init_stack:pending_coinbase_stack
                ~pending_coinbase_stack_state ~next_available_token_before
                ~next_available_token_after
                { transaction = t1; block_data = state_body }
                (unstage @@ Sparse_ledger.handler sparse_ledger)))

    let signed_signed ~wallets i j : Parties.t =
      let full_amount = 8_000_000_000 in
      let fee = Fee.of_int (Random.int full_amount) in
      let receiver_amount =
        Amount.sub (Amount.of_int full_amount) (Amount.of_fee fee)
        |> Option.value_exn
      in
      let acct1 = wallets.(i) in
      let acct2 = wallets.(j) in
      let new_state : _ Snapp_state.V.t =
        Vector.init Snapp_state.Max_state_size.n ~f:Field.of_int
      in
      { fee_payer =
          { Party.Signed.data =
              { body =
                  { pk = acct1.account.public_key
                  ; update =
                      { app_state =
                          Vector.map new_state ~f:(fun x ->
                              Snapp_basic.Set_or_keep.Set x)
                      ; delegate = Keep
                      ; verification_key = Keep
                      ; permissions = Keep
                      ; snapp_uri = Keep
                      ; token_symbol = Keep
                      ; timing = Keep
                      }
                  ; token_id = Token_id.default
                  ; delta =
                      Amount.(
                        Signed.(negate (of_unsigned (of_int full_amount))))
                  ; events = []
                  ; rollup_events = []
                  ; call_data = Field.zero
                  ; depth = 0
                  }
              ; predicate = acct1.account.nonce
              }
          ; authorization = Signature.dummy
          }
      ; other_parties =
          [ { data =
                { body =
                    { pk = acct2.account.public_key
                    ; update = Party.Update.noop
                    ; token_id = Token_id.default
                    ; delta = Amount.Signed.(of_unsigned receiver_amount)
                    ; events = []
                    ; rollup_events = []
                    ; call_data = Field.zero
                    ; depth = 0
                    }
                ; predicate = Accept
                }
            ; authorization = None_given
            }
          ]
      ; protocol_state = Snapp_predicate.Protocol_state.accept
      }

    let%test_unit "merkle_root_after_snapp_command_exn_immutable" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets () in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              Array.iter
                (Array.sub wallets ~pos:1 ~len:(Array.length wallets - 1))
                ~f:(fun { account; private_key = _ } ->
                  Ledger.create_new_account_exn ledger
                    (Account.identifier account)
                    account) ;
              let t1 =
                let i, j = (1, 2) in
                signed_signed ~wallets i j
              in
              let hash_pre = Ledger.merkle_root ledger in
              let _target, `Next_available_token _next_available_token_after =
                let txn_state_view =
                  Mina_state.Protocol_state.Body.view state_body
                in
                Ledger.merkle_root_after_parties_exn ledger ~txn_state_view t1
              in
              let hash_post = Ledger.merkle_root ledger in
              [%test_eq: Field.t] hash_pre hash_post))

    let apply_parties ledger parties =
      let sparse_ledger =
        Sparse_ledger.of_ledger_subset_exn ledger
          (Parties.accounts_accessed parties)
      in
      let _, states =
        Sparse_ledger.apply_parties_unchecked_with_states sparse_ledger
          ~constraint_constants
          ~state_view:(Mina_state.Protocol_state.Body.view state_body)
          parties
        |> Or_error.ok_exn
      in
      let states_rev =
        group_by_parties_rev
          [ []; Parties.parties parties ]
          [ [ List.hd_exn states ]; states ]
      in
      let witnesses =
        let parties : _ Parties_logic.Start_data.t =
          { protocol_state_predicate = Snapp_predicate.Protocol_state.accept
          ; parties
          }
        in
        let commitment = ref Local_state.dummy.transaction_commitment in
        let remaining_parties = ref [ parties ] in
        List.fold states_rev ~init:[]
          ~f:(fun
               witnesses
               ( kind
               , spec
               , (source_global, source_local)
               , (target_global, target_local) )
             ->
            let current_commitment = !commitment in
            let start_parties, next_commitment =
              match kind with
              | `Same ->
                  ([], current_commitment)
              | `New -> (
                  match !remaining_parties with
                  | parties :: rest ->
                      let commitment' = Parties.commitment parties.parties in
                      remaining_parties := rest ;
                      commitment := commitment' ;
                      ([ parties ], commitment')
                  | _ ->
                      failwith "Not enough remaining parties" )
              | `Two_new -> (
                  match !remaining_parties with
                  | parties1 :: parties2 :: rest ->
                      let commitment' = Parties.commitment parties2.parties in
                      remaining_parties := rest ;
                      commitment := commitment' ;
                      ([ parties1; parties2 ], commitment')
                  | _ ->
                      failwith "Not enough remaining parties" )
            in
            let hash_local_state (local : _ Parties_logic.Local_state.t) =
              let hash_parties_stack ps =
                ps |> Parties.Party_or_stack.accumulate_hashes'
                |> List.map
                     ~f:(Parties.Party_or_stack.map ~f:(fun p -> (p, ())))
              in
              { local with
                Parties_logic.Local_state.parties =
                  hash_parties_stack local.parties
              ; call_stack = hash_parties_stack local.call_stack
              }
            in
            let source_local =
              { (hash_local_state source_local) with
                transaction_commitment = current_commitment
              }
            in
            let target_local =
              { (hash_local_state target_local) with
                transaction_commitment = next_commitment
              }
            in
            let w : Parties_segment.Witness.t =
              { global_ledger = source_global.ledger
              ; local_state_init = source_local
              ; start_parties
              ; state_body
              }
            in
            let statement : Statement.With_sok.t =
              { source =
                  { ledger = Sparse_ledger.merkle_root source_global.ledger
                  ; next_available_token =
                      Sparse_ledger.next_available_token source_global.ledger
                  ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                  ; local_state =
                      { source_local with
                        parties =
                          Parties.Party_or_stack.stack_hash source_local.parties
                      ; call_stack =
                          Parties.Party_or_stack.stack_hash
                            source_local.call_stack
                      ; ledger = Sparse_ledger.merkle_root source_local.ledger
                      }
                  }
              ; target =
                  { ledger = Sparse_ledger.merkle_root target_global.ledger
                  ; next_available_token =
                      Sparse_ledger.next_available_token target_global.ledger
                  ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                  ; local_state =
                      { target_local with
                        parties =
                          Parties.Party_or_stack.stack_hash target_local.parties
                      ; call_stack =
                          Parties.Party_or_stack.stack_hash
                            target_local.call_stack
                      ; ledger = Sparse_ledger.merkle_root target_local.ledger
                      }
                  }
              ; supply_increase = Amount.zero
              ; fee_excess =
                  { fee_token_l = Token_id.default
                  ; fee_excess_l =
                      Fee.Signed.of_unsigned
                        (Amount.to_fee source_global.fee_excess)
                  ; fee_token_r = Token_id.default
                  ; fee_excess_r =
                      Fee.Signed.of_unsigned
                        (Amount.to_fee target_global.fee_excess)
                  }
              ; sok_digest = Sok_message.Digest.default
              }
            in
            (w, spec, statement) :: witnesses)
      in
      let open Impl in
      List.fold ~init:((), ()) witnesses ~f:(fun _ (witness, spec, statement) ->
          run_and_check
            (fun () ->
              let s =
                exists Statement.With_sok.typ ~compute:(fun () -> statement)
              in
              Base.Parties_snark.main ~constraint_constants
                (Parties_segment.Basic.to_single_list spec)
                [] s ~witness ;
              fun () -> ())
            ()
          |> Or_error.ok_exn)

    let%test_unit "snapps-based payment" =
      let open Transaction_logic.For_tests in
      Quickcheck.test ~trials:15 Test_spec.gen ~f:(fun { init_ledger; specs } ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let parties = party_send (List.hd_exn specs) in
              Init_ledger.init (module Ledger.Ledger_inner) init_ledger ledger ;
              let w : Parties_segment.Witness.t =
                { global_ledger =
                    Sparse_ledger.of_ledger_subset_exn ledger
                      (Parties.accounts_accessed parties)
                ; local_state_init =
                    { Local_state.dummy with
                      parties = []
                    ; call_stack = []
                    ; ledger = Sparse_ledger.empty ~depth:ledger_depth ()
                    }
                ; start_parties =
                    [ { protocol_state_predicate =
                          Snapp_predicate.Protocol_state.accept
                      ; parties
                      }
                    ]
                ; state_body
                }
              in
              let _, (local_state_post, excess) =
                Ledger.apply_parties_unchecked ledger ~constraint_constants
                  ~state_view:(Mina_state.Protocol_state.Body.view state_body)
                  parties
                |> Or_error.ok_exn
              in
              let statement : Statement.With_sok.t =
                { source =
                    { ledger = Sparse_ledger.merkle_root w.global_ledger
                    ; next_available_token =
                        Sparse_ledger.next_available_token w.global_ledger
                    ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                    ; local_state =
                        { w.local_state_init with
                          parties =
                            Parties.Party_or_stack.stack_hash
                              w.local_state_init.parties
                        ; call_stack =
                            Parties.Party_or_stack.stack_hash
                              w.local_state_init.call_stack
                        ; ledger =
                            Sparse_ledger.merkle_root w.local_state_init.ledger
                        }
                    }
                ; target =
                    { ledger = Ledger.merkle_root ledger
                    ; next_available_token = Ledger.next_available_token ledger
                    ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                    ; local_state =
                        { local_state_post with
                          parties =
                            Parties.Party_or_stack.(
                              With_hashes.stack_hash
                                (accumulate_hashes' local_state_post.parties))
                        ; call_stack =
                            Parties.Party_or_stack.(
                              With_hashes.stack_hash
                                (accumulate_hashes' local_state_post.call_stack))
                        ; ledger = Ledger.merkle_root local_state_post.ledger
                        ; transaction_commitment =
                            w.local_state_init.transaction_commitment
                        }
                    }
                ; supply_increase = Amount.zero
                ; fee_excess =
                    { fee_token_l = Token_id.default
                    ; fee_excess_l =
                        Fee.Signed.of_unsigned (Amount.to_fee excess)
                    ; fee_token_r = Token_id.default
                    ; fee_excess_r = Fee.Signed.zero
                    }
                ; sok_digest = Sok_message.Digest.default
                }
              in
              let open Impl in
              run_and_check
                (fun () ->
                  let s =
                    exists Statement.With_sok.typ ~compute:(fun () -> statement)
                  in
                  Base.Parties_snark.main ~constraint_constants
                    [ { predicate_type = `Nonce_or_accept
                      ; auth_type = Signature
                      ; is_start = `Yes
                      }
                    ; { predicate_type = `Nonce_or_accept
                      ; auth_type = None_given
                      ; is_start = `No
                      }
                    ]
                    [] s ~witness:w ;
                  fun () -> ())
                ())
          |> Or_error.ok_exn
          |> fun ((), ()) -> ())

    (* Disabling until new-style snapp transactions are fully implemented.

       let%test_unit "signed_signed" =
         Test_util.with_randomness 123456789 (fun () ->
             let wallets = random_wallets () in
             Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
                 Array.iter (Array.sub wallets ~pos:1 ~len:2)
                   ~f:(fun {account; private_key= _} ->
                     Ledger.create_new_account_exn ledger
                       (Account.identifier account)
                       account ) ;
                 let i, j = (1, 2) in
                 let t1 = signed_signed ~wallets i j in
                 let txn_state_view =
                   Mina_state.Protocol_state.Body.view state_body
                 in
                 let next_available_token_before =
                   Ledger.next_available_token ledger
                 in
                 let target, `Next_available_token next_available_token_after =
                   Ledger.merkle_root_after_parties_exn ledger ~txn_state_view t1
                 in
                 let mentioned_keys = Parties.accounts_accessed t1 in
                 let sparse_ledger =
                   Sparse_ledger.of_ledger_subset_exn ledger mentioned_keys
                 in
                 let sok_message =
                   Sok_message.create ~fee:Fee.zero
                     ~prover:wallets.(1).account.public_key
                 in
                 let pending_coinbase_stack = Pending_coinbase.Stack.empty in
                 let pending_coinbase_stack_target =
                   pending_coinbase_stack_target (Command (Parties t1))
                     state_body_hash pending_coinbase_stack
                 in
                 let pending_coinbase_stack_state =
                   { Pending_coinbase_stack_state.source= pending_coinbase_stack
                   ; target= pending_coinbase_stack_target }
                 in
                 let snapp_account1, snapp_account2 =
                   Sparse_ledger.snapp_accounts sparse_ledger
                     (Command (Snapp_command t1))
                 in
                 check_snapp_command ~constraint_constants ~sok_message
                   ~state_body
                   ~source:(Ledger.merkle_root ledger)
                   ~target ~init_stack:pending_coinbase_stack
                   ~pending_coinbase_stack_state ~next_available_token_before
                   ~next_available_token_after ~snapp_account1 ~snapp_account2 t1
                   (unstage @@ Sparse_ledger.handler sparse_ledger) ) )
    *)

    let%test_module "multisig_account" =
      ( module struct
        module M_of_n_predicate = struct
          type _witness = (Schnorr.Signature.t * Public_key.t) list

          (* check that two public keys are equal *)
          let eq_pk ((x0, y0) : Public_key.var) ((x1, y1) : Public_key.var) :
              (Boolean.var, _) Checked.t =
            [ Field.Checked.equal x0 x1; Field.Checked.equal y0 y1 ]
            |> Checked.List.all >>= Boolean.all

          (* check that two public keys are not equal *)
          let neq_pk (pk0 : Public_key.var) (pk1 : Public_key.var) :
              (Boolean.var, _) Checked.t =
            eq_pk pk0 pk1 >>| Boolean.not

          (* check that the witness has distinct public keys for each signature *)
          let rec distinct_public_keys = function
            | (_, pk) :: xs ->
                Checked.List.map ~f:(fun (_, pk') -> neq_pk pk pk') xs
                >>= Boolean.Assert.all
                >>= fun () -> distinct_public_keys xs
            | [] ->
                Checked.return ()

          let%snarkydef distinct_public_keys x = distinct_public_keys x

          (* check a signature on msg against a public key *)
          let check_sig pk msg sigma : (Boolean.var, _) Checked.t =
            let%bind (module S) = Inner_curve.Checked.Shifted.create () in
            Schnorr.Checked.verifies (module S) sigma pk msg

          (* verify witness signatures against public keys *)
          let%snarkydef verify_sigs pubkeys commitment witness =
            let%bind pubkeys =
              exists
                (Typ.list ~length:(List.length pubkeys) Inner_curve.typ)
                ~compute:(As_prover.return pubkeys)
            in
            let verify_sig (sigma, pk) : (Boolean.var, _) Checked.t =
              Checked.List.exists pubkeys ~f:(fun pk' ->
                  [ eq_pk pk pk'; check_sig pk' commitment sigma ]
                  |> Checked.List.all >>= Boolean.all)
            in
            Checked.List.map witness ~f:verify_sig >>= Boolean.Assert.all

          let check_witness m pubkeys commitment witness =
            if List.length witness <> m then
              failwith @@ "witness length must be exactly " ^ Int.to_string m
            else
              dummy_constraints ()
              >>= fun () ->
              distinct_public_keys witness
              >>= fun () -> verify_sigs pubkeys commitment witness

          let%test_unit "1-of-1" =
            let gen =
              let open Quickcheck.Generator.Let_syntax in
              let%map sk = Private_key.gen and msg = Field.gen_uniform in
              (sk, Random_oracle.Input.field_elements [| msg |])
            in
            Quickcheck.test ~trials:1 gen ~f:(fun (sk, msg) ->
                let pk = Inner_curve.(scale one sk) in
                (let%bind pk_var =
                   exists Inner_curve.typ ~compute:(As_prover.return pk)
                 in
                 let sigma = Schnorr.sign sk msg in
                 let%bind sigma_var =
                   exists Schnorr.Signature.typ
                     ~compute:(As_prover.return sigma)
                 in
                 let%bind msg_var =
                   exists (Schnorr.message_typ ())
                     ~compute:(As_prover.return msg)
                 in
                 let witness = [ (sigma_var, pk_var) ] in
                 check_witness 1 [ pk ] msg_var witness)
                |> Checked.map ~f:As_prover.return
                |> Fn.flip run_and_check () |> Or_error.ok_exn |> snd)

          let%test_unit "2-of-2" =
            let gen =
              let open Quickcheck.Generator.Let_syntax in
              let%map sk0 = Private_key.gen
              and sk1 = Private_key.gen
              and msg = Field.gen_uniform in
              (sk0, sk1, Random_oracle.Input.field_elements [| msg |])
            in
            Quickcheck.test ~trials:1 gen ~f:(fun (sk0, sk1, msg) ->
                let pk0 = Inner_curve.(scale one sk0) in
                let pk1 = Inner_curve.(scale one sk1) in
                (let%bind pk0_var =
                   exists Inner_curve.typ ~compute:(As_prover.return pk0)
                 in
                 let%bind pk1_var =
                   exists Inner_curve.typ ~compute:(As_prover.return pk1)
                 in
                 let sigma0 = Schnorr.sign sk0 msg in
                 let sigma1 = Schnorr.sign sk1 msg in
                 let%bind sigma0_var =
                   exists Schnorr.Signature.typ
                     ~compute:(As_prover.return sigma0)
                 in
                 let%bind sigma1_var =
                   exists Schnorr.Signature.typ
                     ~compute:(As_prover.return sigma1)
                 in
                 let%bind msg_var =
                   exists (Schnorr.message_typ ())
                     ~compute:(As_prover.return msg)
                 in
                 let witness =
                   [ (sigma0_var, pk0_var); (sigma1_var, pk1_var) ]
                 in
                 check_witness 2 [ pk0; pk1 ] msg_var witness)
                |> Checked.map ~f:As_prover.return
                |> Fn.flip run_and_check () |> Or_error.ok_exn |> snd)
        end

        (* test with a trivial predicate *)
        let%test_unit "trivial snapp predicate" =
          let open Transaction_logic.For_tests in
          let gen =
            let open Quickcheck.Generator.Let_syntax in
            let%map test_spec = Test_spec.gen in
            test_spec
          in
          Quickcheck.test ~trials:1 gen ~f:(fun { init_ledger; specs } ->
              Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
                  Init_ledger.init
                    (module Ledger.Ledger_inner)
                    init_ledger ledger ;
                  let local_dummy_constraints () =
                    let open Run in
                    let b =
                      exists Boolean.typ_unchecked ~compute:(fun _ -> true)
                    in
                    let g =
                      exists Pickles.Step_main_inputs.Inner_curve.typ
                        ~compute:(fun _ -> Tick.Inner_curve.(to_affine_exn one))
                    in
                    let (_ : _) =
                      Pickles.Step_main_inputs.Ops.scale_fast g
                        (`Plus_two_to_len [| b; b |])
                    in
                    let (_ : _) =
                      Pickles.Pairing_main.Scalar_challenge.endo g
                        (Scalar_challenge [ b ])
                    in
                    ()
                  in
                  let spec = List.hd_exn specs in
                  let tag, _, (module P), Pickles.Provers.[ trivial_prover; _ ]
                      =
                    let trivial_rule : _ Pickles.Inductive_rule.t =
                      let trivial_main
                          (tx_commitment : Snapp_statement.Checked.t) :
                          (unit, _) Checked.t =
                        local_dummy_constraints ()
                        |> fun () ->
                        Snapp_statement.Checked.Assert.equal tx_commitment
                          tx_commitment
                        |> return
                      in
                      { identifier = "trivial-rule"
                      ; prevs = []
                      ; main =
                          (fun [] x ->
                            trivial_main x |> Run.run_checked
                            |> fun _ :
                                   unit
                                   Pickles_types.Hlist0.H1
                                     (Pickles_types.Hlist.E01
                                        (Pickles.Inductive_rule.B))
                                   .t ->
                            [])
                      ; main_value = (fun [] _ -> [])
                      }
                    in
                    Pickles.compile ~cache:Cache_dir.cache
                      (module Snapp_statement.Checked)
                      (module Snapp_statement)
                      ~typ:Snapp_statement.typ
                      ~branches:(module Nat.N2)
                      ~max_branching:
                        (module Nat.N2) (* You have to put 2 here... *)
                      ~name:"trivial"
                      ~constraint_constants:
                        (Genesis_constants.Constraint_constants
                         .to_snark_keys_header constraint_constants)
                      ~choices:(fun ~self ->
                        [ trivial_rule
                        ; { identifier = "dummy"
                          ; prevs = [ self; self ]
                          ; main_value = (fun [ _; _ ] _ -> [ true; true ])
                          ; main =
                              (fun [ _; _ ] _ ->
                                local_dummy_constraints ()
                                |> fun () ->
                                (* Unsatisfiable. *)
                                Run.exists Field.typ ~compute:(fun () ->
                                    Run.Field.Constant.zero)
                                |> fun s ->
                                Run.Field.(Assert.equal s (s + one))
                                |> fun () :
                                       ( Snapp_statement.Checked.t
                                       * (Snapp_statement.Checked.t * unit) )
                                       Pickles_types.Hlist0.H1
                                         (Pickles_types.Hlist.E01
                                            (Pickles.Inductive_rule.B))
                                       .t ->
                                [ Boolean.true_; Boolean.true_ ])
                          }
                        ])
                  in
                  let vk =
                    Pickles.Side_loaded.Verification_key.of_compiled tag
                  in
                  let { Transaction_logic.For_tests.Transaction_spec.fee
                      ; sender = sender, sender_nonce
                      ; receiver = trivial_account_pk
                      ; amount
                      } =
                    spec
                  in
                  let vk =
                    With_hash.of_data ~hash_data:Snapp_account.digest_vk vk
                  in
                  let _is_new, _loc =
                    let id =
                      Public_key.compress sender.public_key
                      |> fun pk -> Account_id.create pk Token_id.default
                    in
                    Ledger.get_or_create_account ledger id
                      (Account.create id Balance.(of_int 888_888))
                    |> Or_error.ok_exn
                  in
                  let _is_new, _loc =
                    let id =
                      Account_id.create trivial_account_pk Token_id.default
                    in
                    let account : Account.t =
                      { (Account.create id Balance.(of_int 0)) with
                        permissions =
                          { Permissions.user_default with
                            set_permissions = Proof
                          }
                      ; snapp =
                          Some
                            { Snapp_account.default with
                              verification_key = Some vk
                            }
                      }
                    in
                    Ledger.get_or_create_account ledger id account
                    |> Or_error.ok_exn
                  in
                  let total = Option.value_exn (Amount.add fee amount) in
                  let update_empty_permissions =
                    let permissions =
                      { Permissions.user_default with
                        send = Permissions.Auth_required.Proof
                      }
                      |> Snapp_basic.Set_or_keep.Set
                    in
                    { Party.Update.dummy with permissions }
                  in
                  let fee_payer =
                    { Party.Signed.data =
                        { body =
                            { pk = sender.public_key |> Public_key.compress
                            ; update = update_empty_permissions
                            ; token_id = Token_id.default
                            ; delta = Amount.Signed.(negate (of_unsigned total))
                            ; events = []
                            ; rollup_events = []
                            ; call_data = Field.zero
                            ; depth = 0
                            }
                        ; predicate = sender_nonce
                        }
                        (* Real signature added in below *)
                    ; authorization = Signature.dummy
                    }
                  in
                  let snapp_party_data : Party.Predicated.t =
                    { body =
                        { pk = trivial_account_pk
                        ; update = update_empty_permissions
                        ; token_id = Token_id.default
                        ; delta = Amount.Signed.(of_unsigned amount)
                        ; events = []
                        ; rollup_events = []
                        ; call_data = Field.zero
                        ; depth = 0
                        }
                    ; predicate = Full Snapp_predicate.Account.accept
                    }
                  in
                  let protocol_state = Snapp_predicate.Protocol_state.accept in
                  let ps =
                    Parties.Party_or_stack.of_parties_list
                      ~party_depth:(fun (p : Party.Predicated.t) ->
                        p.body.depth)
                      [ snapp_party_data ]
                    |> Parties.Party_or_stack.accumulate_hashes_predicated
                  in
                  let other_parties_hash =
                    Parties.Party_or_stack.stack_hash ps
                  in
                  let protocol_state_predicate_hash =
                    (*FIXME: is this ok? *)
                    Snapp_predicate.Protocol_state.digest protocol_state
                  in
                  let transaction : Parties.Transaction_commitment.t =
                    (*FIXME: is this correct? *)
                    Parties.Transaction_commitment.create ~other_parties_hash
                      ~protocol_state_predicate_hash
                  in
                  let at_party = Parties.Party_or_stack.stack_hash ps in
                  let tx_statement : Snapp_statement.t =
                    { transaction; at_party }
                  in
                  let handler
                      (Snarky_backendless.Request.With { request; respond }) =
                    match request with _ -> respond Unhandled
                  in
                  let pi : Pickles.Side_loaded.Proof.t =
                    (fun () -> trivial_prover ~handler [] tx_statement)
                    |> Async.Thread_safe.block_on_async_exn
                  in
                  let other_parties =
                    [ { Party.data = snapp_party_data
                      ; authorization = Proof pi
                      }
                    ]
                  in
                  let fee_payer =
                    let txn_comm =
                      Parties.Transaction_commitment.with_fee_payer transaction
                        ~fee_payer_hash:
                          Party.Predicated.(digest (of_signed fee_payer.data))
                    in
                    { fee_payer with
                      authorization =
                        Signature_lib.Schnorr.sign sender.private_key
                          (Random_oracle.Input.field txn_comm)
                    }
                  in
                  let parties : Parties.t =
                    { fee_payer; other_parties; protocol_state }
                  in
                  let w : Parties_segment.Witness.t =
                    { global_ledger =
                        Sparse_ledger.of_ledger_subset_exn ledger
                          (Parties.accounts_accessed parties)
                    ; local_state_init =
                        { parties = []
                        ; call_stack = []
                        ; ledger = Sparse_ledger.empty ~depth:ledger_depth ()
                        ; transaction_commitment = transaction
                        ; token_id = Token_id.default
                        ; excess = Amount.zero
                        ; success = true
                        }
                    ; start_parties =
                        [ { protocol_state_predicate = protocol_state; parties }
                        ]
                    ; state_body
                    }
                  in
                  let _, (local_state_post, excess) =
                    Ledger.apply_parties_unchecked ledger ~constraint_constants
                      ~state_view:
                        (Mina_state.Protocol_state.Body.view state_body)
                      parties
                    |> Or_error.ok_exn
                  in
                  let statement : Statement.With_sok.t =
                    { source =
                        { ledger = Sparse_ledger.merkle_root w.global_ledger
                        ; next_available_token =
                            Sparse_ledger.next_available_token w.global_ledger
                        ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                        ; local_state =
                            { w.local_state_init with
                              parties =
                                Parties.Party_or_stack.With_hashes.stack_hash
                                  w.local_state_init.parties
                            ; call_stack =
                                Parties.Party_or_stack.With_hashes.stack_hash
                                  w.local_state_init.call_stack
                            ; ledger =
                                Sparse_ledger.merkle_root
                                  w.local_state_init.ledger
                            }
                        }
                    ; target =
                        { ledger = Ledger.merkle_root ledger
                        ; next_available_token =
                            Ledger.next_available_token ledger
                        ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                        ; local_state =
                            { local_state_post with
                              parties =
                                Parties.Party_or_stack.(
                                  stack_hash
                                    (accumulate_hashes'
                                       local_state_post.parties))
                            ; call_stack =
                                Parties.Party_or_stack.(
                                  stack_hash
                                    (accumulate_hashes'
                                       local_state_post.call_stack))
                            ; ledger =
                                Ledger.merkle_root local_state_post.ledger
                            ; transaction_commitment =
                                Parties.Transaction_commitment.empty
                            }
                        }
                    ; supply_increase = Amount.zero
                    ; fee_excess =
                        { fee_token_l = Token_id.default
                        ; fee_excess_l =
                            Fee.Signed.of_unsigned (Amount.to_fee excess)
                        ; fee_token_r = Token_id.default
                        ; fee_excess_r = Fee.Signed.zero
                        }
                    ; sok_digest = Sok_message.Digest.default
                    }
                  in
                  let open Impl in
                  run_and_check
                    (fun () ->
                      let s =
                        exists Statement.With_sok.typ ~compute:(fun () ->
                            statement)
                      in
                      let tx_statement =
                        exists Snapp_statement.typ ~compute:(fun () ->
                            tx_statement)
                      in
                      Base.Parties_snark.main ~constraint_constants
                        [ { predicate_type = `Nonce_or_accept
                          ; auth_type = Signature
                          ; is_start = `Yes
                          }
                        ; { predicate_type = `Full
                          ; auth_type = Proof
                          ; is_start = `No
                          }
                        ]
                        [ (0, tx_statement) ] s ~witness:w ;
                      fun () -> ())
                    ())
              |> Or_error.ok_exn
              |> fun ((), ()) -> ())

        type _ Snarky_backendless.Request.t +=
          | Pubkey : int -> Inner_curve.t Snarky_backendless.Request.t
          | Sigma : int -> Schnorr.Signature.t Snarky_backendless.Request.t

        (* test with a 2-of-3 multisig *)
        let%test_unit "snapps-based proved transaction" =
          let open Transaction_logic.For_tests in
          let gen =
            let open Quickcheck.Generator.Let_syntax in
            let%map sk0 = Private_key.gen
            and sk1 = Private_key.gen
            and sk2 = Private_key.gen
            (* index of the key that is not signing the msg *)
            and not_signing = Base_quickcheck.Generator.int_inclusive 0 2
            and test_spec = Test_spec.gen in
            let secrets = (sk0, sk1, sk2) in
            (secrets, not_signing, test_spec)
          in
          Quickcheck.test ~trials:1 gen
            ~f:(fun (secrets, not_signing, { init_ledger; specs }) ->
              let sk0, sk1, sk2 = secrets in
              let pk0 = Inner_curve.(scale one sk0) in
              let pk1 = Inner_curve.(scale one sk1) in
              let pk2 = Inner_curve.(scale one sk2) in
              Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
                  Init_ledger.init
                    (module Ledger.Ledger_inner)
                    init_ledger ledger ;
                  let spec = List.hd_exn specs in
                  let tag, _, (module P), Pickles.Provers.[ multisig_prover; _ ]
                      =
                    let multisig_rule : _ Pickles.Inductive_rule.t =
                      let multisig_main
                          (tx_commitment : Snapp_statement.Checked.t) :
                          (unit, _) Checked.t =
                        let%bind pk0_var =
                          exists Inner_curve.typ
                            ~request:(As_prover.return @@ Pubkey 0)
                        and pk1_var =
                          exists Inner_curve.typ
                            ~request:(As_prover.return @@ Pubkey 1)
                        and pk2_var =
                          exists Inner_curve.typ
                            ~request:(As_prover.return @@ Pubkey 2)
                        in
                        let msg_var =
                          tx_commitment
                          |> Snapp_statement.Checked.to_field_elements
                          |> Random_oracle_input.field_elements
                        in
                        let%bind sigma0_var =
                          exists Schnorr.Signature.typ
                            ~request:(As_prover.return @@ Sigma 0)
                        and sigma1_var =
                          exists Schnorr.Signature.typ
                            ~request:(As_prover.return @@ Sigma 1)
                        and sigma2_var =
                          exists Schnorr.Signature.typ
                            ~request:(As_prover.return @@ Sigma 2)
                        in
                        let witness =
                          [ (sigma0_var, pk0_var)
                          ; (sigma1_var, pk1_var)
                          ; (sigma2_var, pk2_var)
                          ]
                          |> Fn.flip List.drop not_signing
                        in
                        M_of_n_predicate.check_witness 2 [ pk0; pk1; pk2 ]
                          msg_var witness
                      in
                      { identifier = "multisig-rule"
                      ; prevs = []
                      ; main =
                          (fun [] x ->
                            multisig_main x |> Run.run_checked
                            |> fun _ :
                                   unit
                                   Pickles_types.Hlist0.H1
                                     (Pickles_types.Hlist.E01
                                        (Pickles.Inductive_rule.B))
                                   .t ->
                            [])
                      ; main_value = (fun [] _ -> [])
                      }
                    in
                    Pickles.compile ~cache:Cache_dir.cache
                      (module Snapp_statement.Checked)
                      (module Snapp_statement)
                      ~typ:Snapp_statement.typ
                      ~branches:(module Nat.N2)
                      ~max_branching:
                        (module Nat.N2) (* You have to put 2 here... *)
                      ~name:"multisig"
                      ~constraint_constants:
                        (Genesis_constants.Constraint_constants
                         .to_snark_keys_header constraint_constants)
                      ~choices:(fun ~self ->
                        [ multisig_rule
                        ; { identifier = "dummy"
                          ; prevs = [ self; self ]
                          ; main_value = (fun [ _; _ ] _ -> [ true; true ])
                          ; main =
                              (fun [ _; _ ] _ ->
                                let dummy_constraints () =
                                  let open Run in
                                  let b =
                                    exists Boolean.typ_unchecked
                                      ~compute:(fun _ -> true)
                                  in
                                  let g =
                                    exists
                                      Pickles.Step_main_inputs.Inner_curve.typ
                                      ~compute:(fun _ ->
                                        Tick.Inner_curve.(to_affine_exn one))
                                  in
                                  let (_ : _) =
                                    Pickles.Step_main_inputs.Ops.scale_fast g
                                      (`Plus_two_to_len [| b; b |])
                                  in
                                  let (_ : _) =
                                    Pickles.Pairing_main.Scalar_challenge.endo g
                                      (Scalar_challenge [ b ])
                                  in
                                  ()
                                in
                                dummy_constraints ()
                                |> fun () ->
                                (* Unsatisfiable. *)
                                Run.exists Field.typ ~compute:(fun () ->
                                    Run.Field.Constant.zero)
                                |> fun s ->
                                Run.Field.(Assert.equal s (s + one))
                                |> fun () :
                                       ( Snapp_statement.Checked.t
                                       * (Snapp_statement.Checked.t * unit) )
                                       Pickles_types.Hlist0.H1
                                         (Pickles_types.Hlist.E01
                                            (Pickles.Inductive_rule.B))
                                       .t ->
                                [ Boolean.true_; Boolean.true_ ])
                          }
                        ])
                  in
                  let vk =
                    Pickles.Side_loaded.Verification_key.of_compiled tag
                  in
                  let { Transaction_logic.For_tests.Transaction_spec.fee
                      ; sender = sender, sender_nonce
                      ; receiver = multisig_account_pk
                      ; amount
                      } =
                    spec
                  in
                  let vk =
                    With_hash.of_data ~hash_data:Snapp_account.digest_vk vk
                  in
                  let total = Option.value_exn (Amount.add fee amount) in
                  (let _is_new, _loc =
                     let pk = Public_key.compress sender.public_key in
                     let id = Account_id.create pk Token_id.default in
                     Ledger.get_or_create_account ledger id
                       (Account.create id
                          Balance.(Option.value_exn (add_amount zero total)))
                     |> Or_error.ok_exn
                   in
                   let _is_new, loc =
                     let id =
                       Account_id.create multisig_account_pk Token_id.default
                     in
                     Ledger.get_or_create_account ledger id
                       (Account.create id Balance.(of_int 0))
                     |> Or_error.ok_exn
                   in
                   let a = Ledger.get ledger loc |> Option.value_exn in
                   Ledger.set ledger loc
                     { a with
                       permissions =
                         { Permissions.user_default with
                           set_permissions = Proof
                         }
                     ; snapp =
                         Some
                           { (Option.value ~default:Snapp_account.default
                                a.snapp)
                             with
                             verification_key = Some vk
                           }
                     }) ;
                  let update_empty_permissions =
                    let permissions =
                      Snapp_basic.Set_or_keep.Set Permissions.empty
                    in
                    { Party.Update.noop with permissions }
                  in
                  let fee_payer =
                    { Party.Signed.data =
                        { body =
                            { pk = sender.public_key |> Public_key.compress
                            ; update = Party.Update.noop
                            ; token_id = Token_id.default
                            ; delta = Amount.Signed.(negate (of_unsigned total))
                            ; events = []
                            ; rollup_events = []
                            ; call_data = Field.zero
                            ; depth = 0
                            }
                        ; predicate = sender_nonce
                        }
                        (* Real signature added in below *)
                    ; authorization = Signature.dummy
                    }
                  in
                  let snapp_party_data : Party.Predicated.t =
                    { Party.Predicated.Poly.body =
                        { pk = multisig_account_pk
                        ; update = update_empty_permissions
                        ; token_id = Token_id.default
                        ; delta = Amount.Signed.(of_unsigned amount)
                        ; events = []
                        ; rollup_events = []
                        ; call_data = Field.zero
                        ; depth = 0
                        }
                    ; predicate = Full Snapp_predicate.Account.accept
                    }
                  in
                  let protocol_state = Snapp_predicate.Protocol_state.accept in
                  let ps =
                    Parties.Party_or_stack.of_parties_list
                      ~party_depth:(fun (p : Party.Predicated.t) ->
                        p.body.depth)
                      [ snapp_party_data ]
                    |> Parties.Party_or_stack.accumulate_hashes_predicated
                  in
                  let other_parties_hash =
                    Parties.Party_or_stack.stack_hash ps
                  in
                  let protocol_state_predicate_hash =
                    (*FIXME: is this ok? *)
                    Snapp_predicate.Protocol_state.digest protocol_state
                  in
                  let transaction : Parties.Transaction_commitment.t =
                    (*FIXME: is this correct? *)
                    Parties.Transaction_commitment.create ~other_parties_hash
                      ~protocol_state_predicate_hash
                  in
                  let at_party = Parties.Party_or_stack.stack_hash ps in
                  let tx_statement : Snapp_statement.t =
                    { transaction; at_party }
                  in
                  let msg =
                    tx_statement |> Snapp_statement.to_field_elements
                    |> Random_oracle_input.field_elements
                  in
                  let sigma0 = Schnorr.sign sk0 msg in
                  let sigma1 = Schnorr.sign sk1 msg in
                  let sigma2 = Schnorr.sign sk2 msg in
                  let handler
                      (Snarky_backendless.Request.With { request; respond }) =
                    match request with
                    | Pubkey 0 ->
                        respond @@ Provide pk0
                    | Pubkey 1 ->
                        respond @@ Provide pk1
                    | Pubkey 2 ->
                        respond @@ Provide pk2
                    | Sigma 0 ->
                        respond @@ Provide sigma0
                    | Sigma 1 ->
                        respond @@ Provide sigma1
                    | Sigma 2 ->
                        respond @@ Provide sigma2
                    | _ ->
                        respond Unhandled
                  in
                  let pi : Pickles.Side_loaded.Proof.t =
                    (fun () -> multisig_prover ~handler [] tx_statement)
                    |> Async.Thread_safe.block_on_async_exn
                  in
                  let fee_payer =
                    let txn_comm =
                      Parties.Transaction_commitment.with_fee_payer transaction
                        ~fee_payer_hash:
                          Party.Predicated.(digest (of_signed fee_payer.data))
                    in
                    { fee_payer with
                      authorization =
                        Signature_lib.Schnorr.sign sender.private_key
                          (Random_oracle.Input.field txn_comm)
                    }
                  in
                  let parties : Parties.t =
                    { fee_payer
                    ; other_parties =
                        [ { data = snapp_party_data; authorization = Proof pi }
                        ]
                    ; protocol_state
                    }
                  in
                  let w : Parties_segment.Witness.t =
                    { global_ledger =
                        Sparse_ledger.of_ledger_subset_exn ledger
                          (Parties.accounts_accessed parties)
                    ; local_state_init =
                        { parties = []
                        ; call_stack = []
                        ; ledger = Sparse_ledger.empty ~depth:ledger_depth ()
                        ; transaction_commitment = transaction
                        ; token_id = Token_id.default
                        ; excess = Amount.zero
                        ; success = true
                        }
                    ; start_parties =
                        [ { protocol_state_predicate =
                              Snapp_predicate.Protocol_state.accept
                          ; parties
                          }
                        ]
                    ; state_body
                    }
                  in
                  let _, (local_state_post, excess) =
                    Ledger.apply_parties_unchecked ledger ~constraint_constants
                      ~state_view:
                        (Mina_state.Protocol_state.Body.view state_body)
                      parties
                    |> Or_error.ok_exn
                  in
                  let statement : Statement.With_sok.t =
                    { source =
                        { ledger = Sparse_ledger.merkle_root w.global_ledger
                        ; next_available_token =
                            Sparse_ledger.next_available_token w.global_ledger
                        ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                        ; local_state =
                            { w.local_state_init with
                              parties =
                                Parties.Party_or_stack.With_hashes.stack_hash
                                  w.local_state_init.parties
                            ; call_stack =
                                Parties.Party_or_stack.With_hashes.stack_hash
                                  w.local_state_init.call_stack
                            ; ledger =
                                Sparse_ledger.merkle_root
                                  w.local_state_init.ledger
                            }
                        }
                    ; target =
                        { ledger = Ledger.merkle_root ledger
                        ; next_available_token =
                            Ledger.next_available_token ledger
                        ; pending_coinbase_stack = Pending_coinbase.Stack.empty
                        ; local_state =
                            { local_state_post with
                              parties =
                                Parties.Party_or_stack.(
                                  stack_hash
                                    (accumulate_hashes'
                                       local_state_post.parties))
                            ; call_stack =
                                Parties.Party_or_stack.(
                                  stack_hash
                                    (accumulate_hashes'
                                       local_state_post.call_stack))
                            ; ledger =
                                Ledger.merkle_root local_state_post.ledger
                            ; transaction_commitment =
                                Parties.Transaction_commitment.empty
                            }
                        }
                    ; supply_increase = Amount.zero
                    ; fee_excess =
                        { fee_token_l = Token_id.default
                        ; fee_excess_l =
                            Fee.Signed.of_unsigned (Amount.to_fee excess)
                        ; fee_token_r = Token_id.default
                        ; fee_excess_r = Fee.Signed.zero
                        }
                    ; sok_digest = Sok_message.Digest.default
                    }
                  in
                  let open Impl in
                  run_and_check
                    (fun () ->
                      let s =
                        exists Statement.With_sok.typ ~compute:(fun () ->
                            statement)
                      in
                      let tx_statement =
                        exists Snapp_statement.typ ~compute:(fun () ->
                            tx_statement)
                      in
                      Base.Parties_snark.main ~constraint_constants
                        [ { predicate_type = `Nonce_or_accept
                          ; auth_type = Signature
                          ; is_start = `Yes
                          }
                        ; { predicate_type = `Full
                          ; auth_type = Proof
                          ; is_start = `No
                          }
                        ]
                        [ (0, tx_statement) ] s ~witness:w ;
                      fun () -> ())
                    ())
              |> Or_error.ok_exn
              |> fun ((), ()) -> ())
      end )

    let account_fee = Fee.to_int constraint_constants.account_creation_fee

    let test_transaction ~constraint_constants ?txn_global_slot ledger txn =
      let source = Ledger.merkle_root ledger in
      let pending_coinbase_stack = Pending_coinbase.Stack.empty in
      let next_available_token = Ledger.next_available_token ledger in
      let state_body, state_body_hash =
        match txn_global_slot with
        | None ->
            (state_body, state_body_hash)
        | Some txn_global_slot ->
            let state_body =
              let state =
                (* NB: The [previous_state_hash] is a dummy, do not use. *)
                Mina_state.Protocol_state.create
                  ~previous_state_hash:Tick0.Field.zero ~body:state_body
              in
              let consensus_state_at_slot =
                Consensus.Data.Consensus_state.Value.For_tests
                .with_global_slot_since_genesis
                  (Mina_state.Protocol_state.consensus_state state)
                  txn_global_slot
              in
              Mina_state.Protocol_state.(
                create_value
                  ~previous_state_hash:(previous_state_hash state)
                  ~genesis_state_hash:(genesis_state_hash state)
                  ~blockchain_state:(blockchain_state state)
                  ~consensus_state:consensus_state_at_slot
                  ~constants:
                    (Protocol_constants_checked.value_of_t
                       Genesis_constants.compiled.protocol))
                .body
            in
            let state_body_hash =
              Mina_state.Protocol_state.Body.hash state_body
            in
            (state_body, state_body_hash)
      in
      let txn_state_view : Snapp_predicate.Protocol_state.View.t =
        Mina_state.Protocol_state.Body.view state_body
      in
      let mentioned_keys, pending_coinbase_stack_target =
        let pending_coinbase_stack =
          Pending_coinbase.Stack.push_state state_body_hash
            pending_coinbase_stack
        in
        match (txn : Transaction.Valid.t) with
        | Command (Signed_command uc) ->
            ( Signed_command.accounts_accessed ~next_available_token
                (uc :> Signed_command.t)
            , pending_coinbase_stack )
        | Command (Parties _) ->
            failwith "Parties commands not yet supported"
        | Fee_transfer ft ->
            (Fee_transfer.receivers ft, pending_coinbase_stack)
        | Coinbase cb ->
            ( Coinbase.accounts_accessed cb
            , Pending_coinbase.Stack.push_coinbase cb pending_coinbase_stack )
      in
      let sok_signer =
        match to_preunion (txn :> Transaction.t) with
        | `Transaction t ->
            (Transaction_union.of_transaction t).signer |> Public_key.compress
        | `Parties c ->
            Account_id.public_key (Parties.fee_payer c)
      in
      let sparse_ledger =
        Sparse_ledger.of_ledger_subset_exn ledger mentioned_keys
      in
      let _undo =
        Or_error.ok_exn
        @@ Ledger.apply_transaction ledger ~constraint_constants ~txn_state_view
             (txn :> Transaction.t)
      in
      let target = Ledger.merkle_root ledger in
      let sok_message = Sok_message.create ~fee:Fee.zero ~prover:sok_signer in
      check_transaction ~constraint_constants ~sok_message ~source ~target
        ~init_stack:pending_coinbase_stack
        ~pending_coinbase_stack_state:
          { Pending_coinbase_stack_state.source = pending_coinbase_stack
          ; target = pending_coinbase_stack_target
          }
        ~next_available_token_before:next_available_token
        ~next_available_token_after:(Ledger.next_available_token ledger)
        ~snapp_account1:None ~snapp_account2:None
        { transaction = txn; block_data = state_body }
        (unstage @@ Sparse_ledger.handler sparse_ledger)

    let%test_unit "account creation fee - user commands" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets ~n:3 () |> Array.to_list in
          let sender = List.hd_exn wallets in
          let receivers = List.tl_exn wallets in
          let txns_per_receiver = 2 in
          let amount = 8_000_000_000 in
          let txn_fee = 2_000_000_000 in
          let memo =
            Signed_command_memo.create_by_digesting_string_exn
              (Test_util.arbitrary_string
                 ~len:Signed_command_memo.max_digestible_string_length)
          in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let _, ucs =
                let receivers =
                  List.fold ~init:receivers
                    (List.init (txns_per_receiver - 1) ~f:Fn.id)
                    ~f:(fun acc _ -> receivers @ acc)
                in
                List.fold receivers ~init:(Account.Nonce.zero, [])
                  ~f:(fun (nonce, txns) receiver ->
                    let uc =
                      user_command ~fee_payer:sender
                        ~source_pk:(Account.public_key sender.account)
                        ~receiver_pk:(Account.public_key receiver.account)
                        ~fee_token:Token_id.default ~token:Token_id.default
                        amount (Fee.of_int txn_fee) nonce memo
                    in
                    (Account.Nonce.succ nonce, txns @ [ uc ]))
              in
              Ledger.create_new_account_exn ledger
                (Account.identifier sender.account)
                sender.account ;
              let () =
                List.iter ucs ~f:(fun uc ->
                    test_transaction ~constraint_constants ledger
                      (Transaction.Command (Signed_command uc)))
              in
              List.iter receivers ~f:(fun receiver ->
                  check_balance
                    (Account.identifier receiver.account)
                    ((amount * txns_per_receiver) - account_fee)
                    ledger) ;
              check_balance
                (Account.identifier sender.account)
                ( Balance.to_int sender.account.balance
                - (amount + txn_fee) * txns_per_receiver * List.length receivers
                )
                ledger))

    let%test_unit "account creation fee - fee transfers" =
      Test_util.with_randomness 123456789 (fun () ->
          let receivers = random_wallets ~n:3 () |> Array.to_list in
          let txns_per_receiver = 3 in
          let fee = 8_000_000_000 in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let fts =
                let receivers =
                  List.fold ~init:receivers
                    (List.init (txns_per_receiver - 1) ~f:Fn.id)
                    ~f:(fun acc _ -> receivers @ acc)
                  |> One_or_two.group_list
                in
                List.fold receivers ~init:[] ~f:(fun txns receiver ->
                    let ft : Fee_transfer.t =
                      Or_error.ok_exn @@ Fee_transfer.of_singles
                      @@ One_or_two.map receiver ~f:(fun receiver ->
                             Fee_transfer.Single.create
                               ~receiver_pk:receiver.account.public_key
                               ~fee:(Currency.Fee.of_int fee)
                               ~fee_token:receiver.account.token_id)
                    in
                    txns @ [ ft ])
              in
              let () =
                List.iter fts ~f:(fun ft ->
                    let txn = Transaction.Fee_transfer ft in
                    test_transaction ~constraint_constants ledger txn)
              in
              List.iter receivers ~f:(fun receiver ->
                  check_balance
                    (Account.identifier receiver.account)
                    ((fee * txns_per_receiver) - account_fee)
                    ledger)))

    let%test_unit "account creation fee - coinbase" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets ~n:3 () in
          let receiver = wallets.(0) in
          let other = wallets.(1) in
          let dummy_account = wallets.(2) in
          let reward = 10_000_000_000 in
          let fee = Fee.to_int constraint_constants.account_creation_fee in
          let coinbase_count = 3 in
          let ft_count = 2 in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let _, cbs =
                let fts =
                  List.map (List.init ft_count ~f:Fn.id) ~f:(fun _ ->
                      Coinbase.Fee_transfer.create
                        ~receiver_pk:other.account.public_key
                        ~fee:constraint_constants.account_creation_fee)
                in
                List.fold ~init:(fts, []) (List.init coinbase_count ~f:Fn.id)
                  ~f:(fun (fts, cbs) _ ->
                    let cb =
                      Coinbase.create
                        ~amount:(Currency.Amount.of_int reward)
                        ~receiver:receiver.account.public_key
                        ~fee_transfer:(List.hd fts)
                      |> Or_error.ok_exn
                    in
                    (Option.value ~default:[] (List.tl fts), cb :: cbs))
              in
              Ledger.create_new_account_exn ledger
                (Account.identifier dummy_account.account)
                dummy_account.account ;
              let () =
                List.iter cbs ~f:(fun cb ->
                    let txn = Transaction.Coinbase cb in
                    test_transaction ~constraint_constants ledger txn)
              in
              let fees = fee * ft_count in
              check_balance
                (Account.identifier receiver.account)
                ((reward * coinbase_count) - account_fee - fees)
                ledger ;
              check_balance
                (Account.identifier other.account)
                (fees - account_fee) ledger))

    module Pc_with_init_stack = struct
      type t =
        { pc : Pending_coinbase_stack_state.t
        ; init_stack : Pending_coinbase.Stack.t
        }
    end

    let test_base_and_merge ~state_hash_and_body1 ~state_hash_and_body2
        ~carryforward1 ~carryforward2 =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets () in
          (*let state_body = Lazy.force state_body in
            let state_body_hash = Lazy.force state_body_hash in*)
          let state_body_hash1, state_body1 = state_hash_and_body1 in
          let state_body_hash2, state_body2 = state_hash_and_body2 in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              Array.iter wallets ~f:(fun { account; private_key = _ } ->
                  Ledger.create_new_account_exn ledger
                    (Account.identifier account)
                    account) ;
              let memo =
                Signed_command_memo.create_by_digesting_string_exn
                  (Test_util.arbitrary_string
                     ~len:Signed_command_memo.max_digestible_string_length)
              in
              let t1 =
                user_command_with_wallet wallets ~sender:0 ~receiver:1
                  8_000_000_000
                  (Fee.of_int (Random.int 20 * 1_000_000_000))
                  ~fee_token:Token_id.default ~token:Token_id.default
                  Account.Nonce.zero memo
              in
              let t2 =
                user_command_with_wallet wallets ~sender:1 ~receiver:2
                  8_000_000_000
                  (Fee.of_int (Random.int 20 * 1_000_000_000))
                  ~fee_token:Token_id.default ~token:Token_id.default
                  Account.Nonce.zero memo
              in
              let sok_digest =
                Sok_message.create ~fee:Fee.zero
                  ~prover:wallets.(0).account.public_key
                |> Sok_message.digest
              in
              let next_available_token1 = Ledger.next_available_token ledger in
              let sparse_ledger =
                Sparse_ledger.of_ledger_subset_exn ledger
                  (List.concat_map
                     ~f:(fun t ->
                       (* NB: Shouldn't assume the same next_available_token
                          for each command normally, but we know statically
                          that these are payments in this test.
                       *)
                       Signed_command.accounts_accessed
                         ~next_available_token:next_available_token1
                         (Signed_command.forget_check t))
                     [ t1; t2 ])
              in
              let init_stack1 = Pending_coinbase.Stack.empty in
              let pending_coinbase_stack_state1 =
                (* No coinbase to add to the stack. *)
                let stack_with_state =
                  Pending_coinbase.Stack.push_state state_body_hash1 init_stack1
                in
                (* Since protocol state body is added once per block, the
                   source would already have the state if [carryforward=true]
                   from the previous transaction in the sequence of
                   transactions in a block. We add state to [init_stack] and
                   then check that it is equal to the target.
                *)
                let source_stack, target_stack =
                  if carryforward1 then (stack_with_state, stack_with_state)
                  else (init_stack1, stack_with_state)
                in
                { Pc_with_init_stack.pc =
                    { source = source_stack; target = target_stack }
                ; init_stack = init_stack1
                }
              in
              let proof12 =
                of_user_command' sok_digest ledger t1
                  pending_coinbase_stack_state1.init_stack
                  pending_coinbase_stack_state1.pc state_body1
                  (unstage @@ Sparse_ledger.handler sparse_ledger)
              in
              let current_global_slot =
                Mina_state.Protocol_state.Body.consensus_state state_body1
                |> Consensus.Data.Consensus_state.global_slot_since_genesis
              in
              let sparse_ledger =
                Sparse_ledger.apply_user_command_exn ~constraint_constants
                  ~txn_global_slot:current_global_slot sparse_ledger
                  (t1 :> Signed_command.t)
              in
              let pending_coinbase_stack_state2, state_body2 =
                let previous_stack = pending_coinbase_stack_state1.pc.target in
                let stack_with_state2 =
                  Pending_coinbase.Stack.(
                    push_state state_body_hash2 previous_stack)
                in
                (* No coinbase to add. *)
                let source_stack, target_stack, init_stack, state_body2 =
                  if carryforward2 then
                    (* Source and target already have the protocol state,
                       init_stack will be such that
                       [init_stack + state_body_hash1 = target = source].
                    *)
                    (previous_stack, previous_stack, init_stack1, state_body1)
                  else
                    (* Add the new state such that
                       [previous_stack + state_body_hash2
                        = init_stack + state_body_hash2
                        = target].
                    *)
                    ( previous_stack
                    , stack_with_state2
                    , previous_stack
                    , state_body2 )
                in
                ( { Pc_with_init_stack.pc =
                      { source = source_stack; target = target_stack }
                  ; init_stack
                  }
                , state_body2 )
              in
              ignore
                ( Ledger.apply_user_command ~constraint_constants ledger
                    ~txn_global_slot:current_global_slot t1
                  |> Or_error.ok_exn
                  : Ledger.Transaction_applied.Signed_command_applied.t ) ;
              [%test_eq: Frozen_ledger_hash.t]
                (Ledger.merkle_root ledger)
                (Sparse_ledger.merkle_root sparse_ledger) ;
              let proof23 =
                of_user_command' sok_digest ledger t2
                  pending_coinbase_stack_state2.init_stack
                  pending_coinbase_stack_state2.pc state_body2
                  (unstage @@ Sparse_ledger.handler sparse_ledger)
              in
              let current_global_slot =
                Mina_state.Protocol_state.Body.consensus_state state_body2
                |> Consensus.Data.Consensus_state.global_slot_since_genesis
              in
              let sparse_ledger =
                Sparse_ledger.apply_user_command_exn ~constraint_constants
                  ~txn_global_slot:current_global_slot sparse_ledger
                  (t2 :> Signed_command.t)
              in
              ignore
                ( Ledger.apply_user_command ledger ~constraint_constants
                    ~txn_global_slot:current_global_slot t2
                  |> Or_error.ok_exn
                  : Ledger.Transaction_applied.Signed_command_applied.t ) ;
              [%test_eq: Frozen_ledger_hash.t]
                (Ledger.merkle_root ledger)
                (Sparse_ledger.merkle_root sparse_ledger) ;
              let proof13 =
                Async.Thread_safe.block_on_async_exn (fun () ->
                    merge ~sok_digest proof12 proof23)
                |> Or_error.ok_exn
              in
              Async.Thread_safe.block_on_async (fun () ->
                  Proof.verify [ (proof13.statement, proof13.proof) ])
              |> Result.ok_exn))

    let%test "base_and_merge: transactions in one block (t1,t2 in b1), \
              carryforward the state from a previous transaction t0 in b1" =
      let state_hash_and_body1 = (state_body_hash, state_body) in
      test_base_and_merge ~state_hash_and_body1
        ~state_hash_and_body2:state_hash_and_body1 ~carryforward1:true
        ~carryforward2:true

    (* No new state body, carryforward the stack from the previous transaction*)

    let%test "base_and_merge: transactions in one block (t1,t2 in b1), don't \
              carryforward the state from a previous transaction t0 in b1" =
      let state_hash_and_body1 = (state_body_hash, state_body) in
      test_base_and_merge ~state_hash_and_body1
        ~state_hash_and_body2:state_hash_and_body1 ~carryforward1:false
        ~carryforward2:true

    let%test "base_and_merge: transactions in two different blocks (t1,t2 in \
              b1, b2 resp.), carryforward the state from a previous \
              transaction t0 in b1" =
      let state_hash_and_body1 =
        let state_body0 =
          Mina_state.Protocol_state.negative_one
            ~genesis_ledger:Genesis_ledger.(Packed.t for_unit_tests)
            ~genesis_epoch_data:Consensus.Genesis_epoch_data.for_unit_tests
            ~constraint_constants ~consensus_constants
          |> Mina_state.Protocol_state.body
        in
        let state_body_hash0 =
          Mina_state.Protocol_state.Body.hash state_body0
        in
        (state_body_hash0, state_body0)
      in
      let state_hash_and_body2 = (state_body_hash, state_body) in
      test_base_and_merge ~state_hash_and_body1 ~state_hash_and_body2
        ~carryforward1:true ~carryforward2:false

    (*t2 is in a new state, therefore do not carryforward the previous state*)

    let%test "base_and_merge: transactions in two different blocks (t1,t2 in \
              b1, b2 resp.), don't carryforward the state from a previous \
              transaction t0 in b1" =
      let state_hash_and_body1 =
        let state_body0 =
          Mina_state.Protocol_state.negative_one
            ~genesis_ledger:Genesis_ledger.(Packed.t for_unit_tests)
            ~genesis_epoch_data:Consensus.Genesis_epoch_data.for_unit_tests
            ~constraint_constants ~consensus_constants
          |> Mina_state.Protocol_state.body
        in
        let state_body_hash0 =
          Mina_state.Protocol_state.Body.hash state_body0
        in
        (state_body_hash0, state_body0)
      in
      let state_hash_and_body2 = (state_body_hash, state_body) in
      test_base_and_merge ~state_hash_and_body1 ~state_hash_and_body2
        ~carryforward1:false ~carryforward2:false

    let create_account pk token balance =
      Account.create (Account_id.create pk token) (Balance.of_int balance)

    let test_user_command_with_accounts ~constraint_constants ~ledger ~accounts
        ~signer ~fee ~fee_payer_pk ~fee_token ?memo ?valid_until ?nonce body =
      let memo =
        match memo with
        | Some memo ->
            memo
        | None ->
            Signed_command_memo.create_by_digesting_string_exn
              (Test_util.arbitrary_string
                 ~len:Signed_command_memo.max_digestible_string_length)
      in
      Array.iter accounts ~f:(fun account ->
          Ledger.create_new_account_exn ledger
            (Account.identifier account)
            account) ;
      let get_account aid =
        Option.bind
          (Ledger.location_of_account ledger aid)
          ~f:(Ledger.get ledger)
      in
      let nonce =
        match nonce with
        | Some nonce ->
            nonce
        | None -> (
            match get_account (Account_id.create fee_payer_pk fee_token) with
            | Some { nonce; _ } ->
                nonce
            | None ->
                failwith
                  "Could not infer a valid nonce for this test. Provide one \
                   explicitly" )
      in
      let payload =
        Signed_command.Payload.create ~fee ~fee_payer_pk ~fee_token ~nonce
          ~valid_until ~memo ~body
      in
      let signer = Signature_lib.Keypair.of_private_key_exn signer in
      let user_command = Signed_command.sign signer payload in
      let next_available_token = Ledger.next_available_token ledger in
      test_transaction ~constraint_constants ledger
        (Command (Signed_command user_command)) ;
      let fee_payer = Signed_command.Payload.fee_payer payload in
      let source =
        Signed_command.Payload.source ~next_available_token payload
      in
      let receiver =
        Signed_command.Payload.receiver ~next_available_token payload
      in
      let fee_payer_account = get_account fee_payer in
      let source_account = get_account source in
      let receiver_account = get_account receiver in
      ( `Fee_payer_account fee_payer_account
      , `Source_account source_account
      , `Receiver_account receiver_account )

    let random_int_incl l u = Quickcheck.random_value (Int.gen_incl l u)

    let sub_amount amt bal = Option.value_exn (Balance.sub_amount bal amt)

    let add_amount amt bal = Option.value_exn (Balance.add_amount bal amt)

    let sub_fee fee = sub_amount (Amount.of_fee fee)

    let%test_unit "transfer non-default tokens to a new account: fails but \
                   charges fee" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let amount =
                Amount.of_int (random_int_incl 0 30 * 1_000_000_000)
              in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.equal accounts.(1).balance source_account.balance) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "transfer non-default tokens to an existing account" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let amount =
                Amount.of_int (random_int_incl 0 30 * 1_000_000_000)
              in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              let expected_source_balance =
                accounts.(1).balance |> sub_amount amount
              in
              assert (
                Balance.equal source_account.balance expected_source_balance ) ;
              let expected_receiver_balance =
                accounts.(2).balance |> add_amount amount
              in
              assert (
                Balance.equal receiver_account.balance expected_receiver_balance
              )))

    let%test_unit "insufficient account creation fee for non-default token \
                   transfer" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int 20_000_000_000 in
              let amount =
                Amount.of_int (random_int_incl 0 30 * 1_000_000_000)
              in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              let expected_source_balance = accounts.(1).balance in
              assert (
                Balance.equal source_account.balance expected_source_balance ) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "insufficient source balance for non-default token transfer" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let amount = Amount.of_int 40_000_000_000 in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              let expected_source_balance = accounts.(1).balance in
              assert (
                Balance.equal source_account.balance expected_source_balance ) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "transfer non-existing source" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let amount = Amount.of_int 20_000_000_000 in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Option.is_none source_account) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "payment predicate failure" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let amount = Amount.of_int 20_000_000_000 in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Payment { source_pk; receiver_pk; token_id; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              let expected_source_balance = accounts.(1).balance in
              assert (
                Balance.equal source_account.balance expected_source_balance ) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "delegation predicate failure" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account source_pk token_id 30_000_000_000
                 ; create_account receiver_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Stake_delegation
                     (Set_delegate
                        { delegator = source_pk; new_delegate = receiver_pk }))
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Public_key.Compressed.equal
                  (Option.value_exn source_account.delegate)
                  source_pk ) ;
              assert (Option.is_some receiver_account)))

    let%test_unit "delegation delegatee does not exist" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Stake_delegation
                     (Set_delegate
                        { delegator = source_pk; new_delegate = receiver_pk }))
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let source_account = Option.value_exn source_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Public_key.Compressed.equal
                  (Option.value_exn source_account.delegate)
                  source_pk ) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "delegation delegator does not exist" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              let fee_payer_pk = wallets.(0).account.public_key in
              let source_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account receiver_pk token_id 30_000_000_000
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account source_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Stake_delegation
                     (Set_delegate
                        { delegator = source_pk; new_delegate = receiver_pk }))
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Option.is_none source_account) ;
              assert (Option.is_some receiver_account)))

    let%test_unit "timed account - transactions" =
      Test_util.with_randomness 123456789 (fun () ->
          let wallets = random_wallets ~n:3 () in
          let sender = wallets.(0) in
          let receivers = Array.to_list wallets |> List.tl_exn in
          let txns_per_receiver = 2 in
          let amount = 8_000_000_000 in
          let txn_fee = 2_000_000_000 in
          let memo =
            Signed_command_memo.create_by_digesting_string_exn
              (Test_util.arbitrary_string
                 ~len:Signed_command_memo.max_digestible_string_length)
          in
          let balance = Balance.of_int 100_000_000_000_000 in
          let initial_minimum_balance = Balance.of_int 80_000_000_000_000 in
          let cliff_time = Global_slot.of_int 1000 in
          let cliff_amount = Amount.of_int 10000 in
          let vesting_period = Global_slot.of_int 10 in
          let vesting_increment = Amount.of_int 1 in
          let txn_global_slot = Global_slot.of_int 1002 in
          let sender =
            { sender with
              account =
                Or_error.ok_exn
                @@ Account.create_timed
                     (Account.identifier sender.account)
                     balance ~initial_minimum_balance ~cliff_time ~cliff_amount
                     ~vesting_period ~vesting_increment
            }
          in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let _, ucs =
                let receiver_ids =
                  List.init (List.length receivers) ~f:(( + ) 1)
                in
                let receivers =
                  List.fold ~init:receiver_ids
                    (List.init (txns_per_receiver - 1) ~f:Fn.id)
                    ~f:(fun acc _ -> receiver_ids @ acc)
                in
                List.fold receivers ~init:(Account.Nonce.zero, [])
                  ~f:(fun (nonce, txns) receiver ->
                    let uc =
                      user_command_with_wallet wallets ~sender:0 ~receiver
                        amount (Fee.of_int txn_fee) ~fee_token:Token_id.default
                        ~token:Token_id.default nonce memo
                    in
                    (Account.Nonce.succ nonce, txns @ [ uc ]))
              in
              Ledger.create_new_account_exn ledger
                (Account.identifier sender.account)
                sender.account ;
              let () =
                List.iter ucs ~f:(fun uc ->
                    test_transaction ~constraint_constants ~txn_global_slot
                      ledger (Transaction.Command (Signed_command uc)))
              in
              List.iter receivers ~f:(fun receiver ->
                  check_balance
                    (Account.identifier receiver.account)
                    ((amount * txns_per_receiver) - account_fee)
                    ledger) ;
              check_balance
                (Account.identifier sender.account)
                ( Balance.to_int sender.account.balance
                - (amount + txn_fee) * txns_per_receiver * List.length receivers
                )
                ledger))

    let%test_unit "create own new token" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:1 () in
              let signer = wallets.(0).private_key in
              (* Fee payer is the new token owner. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let fee_token = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account _also_token_owner_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_new_token
                     { token_owner_pk; disable_new_accounts = false })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none token_owner_account.delegate) ;
              assert (
                Token_permissions.equal token_owner_account.token_permissions
                  (Token_owned { disable_new_accounts = false }) )))

    let%test_unit "create new token for a different pk" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee payer and new token owner are distinct. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account _also_token_owner_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_new_token
                     { token_owner_pk; disable_new_accounts = false })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none token_owner_account.delegate) ;
              assert (
                Token_permissions.equal token_owner_account.token_permissions
                  (Token_owned { disable_new_accounts = false }) )))

    let%test_unit "create new token for a different pk new accounts disabled" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee payer and new token owner are distinct. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account _also_token_owner_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_new_token
                     { token_owner_pk; disable_new_accounts = true })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none token_owner_account.delegate) ;
              assert (
                Token_permissions.equal token_owner_account.token_permissions
                  (Token_owned { disable_new_accounts = true }) )))

    let%test_unit "create own new token account" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and receiver are the same, token owner differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = fee_payer_pk in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance) ;
              assert (Option.is_none receiver_account.delegate) ;
              assert (
                Token_permissions.equal receiver_account.token_permissions
                  (Not_owned { account_disabled = false }) )))

    let%test_unit "create new token account for a different pk" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner differ. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance) ;
              assert (Option.is_none receiver_account.delegate) ;
              assert (
                Token_permissions.equal receiver_account.token_permissions
                  (Not_owned { account_disabled = false }) )))

    let%test_unit "create new token account for a different pk in a locked \
                   token" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and token owner are the same, receiver differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = true }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance) ;
              assert (Option.is_none receiver_account.delegate) ;
              assert (
                Token_permissions.equal receiver_account.token_permissions
                  (Not_owned { account_disabled = false }) )))

    let%test_unit "create new own locked token account in a locked token" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and receiver are the same, token owner differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = fee_payer_pk in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = true }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = true
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance) ;
              assert (Option.is_none receiver_account.delegate) ;
              assert (
                Token_permissions.equal receiver_account.token_permissions
                  (Not_owned { account_disabled = true }) )))

    let%test_unit "create new token account fails for locked token, non-owner \
                   fee-payer" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner differ. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = true }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "create new locked token account fails for unlocked token, \
                   non-owner fee-payer" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner differ. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = true
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "create new token account fails if account exists" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner differ. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              (* No account creation fee: the command fails. *)
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance)))

    let%test_unit "create new token account fails if receiver is token owner" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Receiver and token owner are the same, fee-payer differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = token_owner_pk in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let receiver_account = Option.value_exn receiver_account in
              (* No account creation fee: the command fails. *)
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Balance.(equal zero) receiver_account.balance)))

    let%test_unit "create new token account fails if claimed token owner \
                   doesn't own the token" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner differ. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = wallets.(2).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account token_owner_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              (* No account creation fee: the command fails. *)
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) token_owner_account.balance) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "create new token account fails if claimed token owner is \
                   also the account creation target and does not exist" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:3 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner are the same. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk = fee_payer_pk
                     ; token_id
                     ; receiver_pk = fee_payer_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              (* No account creation fee: the command fails. *)
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Option.is_none token_owner_account) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "create new token account works for default token" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and receiver are the same, token owner differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Token_id.default in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000 |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account _token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Create_token_account
                     { token_owner_pk
                     ; token_id
                     ; receiver_pk
                     ; account_disabled = false
                     })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
                |> sub_fee constraint_constants.account_creation_fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Balance.(equal zero) receiver_account.balance) ;
              assert (
                Public_key.Compressed.equal receiver_pk
                  (Option.value_exn receiver_account.delegate) ) ;
              assert (
                Token_permissions.equal receiver_account.token_permissions
                  (Not_owned { account_disabled = false }) )))

    let%test_unit "mint tokens in owner's account" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:1 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer, receiver, and token owner are the same. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = fee_payer_pk in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account _token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              let expected_receiver_balance =
                accounts.(1).balance |> add_amount amount
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Balance.equal expected_receiver_balance receiver_account.balance
              )))

    let%test_unit "mint tokens in another pk's account" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and token owner are the same, receiver differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              let expected_receiver_balance =
                accounts.(2).balance |> add_amount amount
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Balance.equal accounts.(1).balance token_owner_account.balance
              ) ;
              assert (
                Balance.equal expected_receiver_balance receiver_account.balance
              )))

    let%test_unit "mint tokens fails if the claimed token owner is not the \
                   token owner" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and token owner are the same, receiver differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account token_owner_pk token_id 0
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Balance.equal accounts.(1).balance token_owner_account.balance
              ) ;
              assert (
                Balance.equal accounts.(2).balance receiver_account.balance )))

    let%test_unit "mint tokens fails if the token owner account is not present"
        =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and token owner are the same, receiver differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (Option.is_none token_owner_account) ;
              assert (
                Balance.equal accounts.(1).balance receiver_account.balance )))

    let%test_unit "mint tokens fails if the fee-payer does not have permission \
                   to mint" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and receiver are the same, token owner differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = wallets.(1).account.public_key in
              let receiver_pk = fee_payer_pk in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                 ; create_account receiver_pk token_id 0
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let receiver_account = Option.value_exn receiver_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Balance.equal accounts.(1).balance token_owner_account.balance
              ) ;
              assert (
                Balance.equal accounts.(2).balance receiver_account.balance )))

    let%test_unit "mint tokens fails if the receiver account is not present" =
      Test_util.with_randomness 123456789 (fun () ->
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              let wallets = random_wallets ~n:2 () in
              let signer = wallets.(0).private_key in
              (* Fee-payer and fee payer are the same, receiver differs. *)
              let fee_payer_pk = wallets.(0).account.public_key in
              let token_owner_pk = fee_payer_pk in
              let receiver_pk = wallets.(1).account.public_key in
              let fee_token = Token_id.default in
              let token_id = Quickcheck.random_value Token_id.gen_non_default in
              let amount =
                Amount.of_int (random_int_incl 2 15 * 1_000_000_000)
              in
              let accounts =
                [| create_account fee_payer_pk fee_token 20_000_000_000
                 ; { (create_account token_owner_pk token_id 0) with
                     token_permissions =
                       Token_owned { disable_new_accounts = false }
                   }
                |]
              in
              let fee = Fee.of_int (random_int_incl 2 15 * 1_000_000_000) in
              let ( `Fee_payer_account fee_payer_account
                  , `Source_account token_owner_account
                  , `Receiver_account receiver_account ) =
                test_user_command_with_accounts ~constraint_constants ~ledger
                  ~accounts ~signer ~fee ~fee_payer_pk ~fee_token
                  (Mint_tokens { token_owner_pk; token_id; receiver_pk; amount })
              in
              let fee_payer_account = Option.value_exn fee_payer_account in
              let token_owner_account = Option.value_exn token_owner_account in
              let expected_fee_payer_balance =
                accounts.(0).balance |> sub_fee fee
              in
              assert (
                Balance.equal fee_payer_account.balance
                  expected_fee_payer_balance ) ;
              assert (
                Balance.equal accounts.(1).balance token_owner_account.balance
              ) ;
              assert (Option.is_none receiver_account)))

    let%test_unit "unchanged timings for fee transfers and coinbase" =
      Test_util.with_randomness 123456789 (fun () ->
          let receivers =
            Array.init 2 ~f:(fun _ ->
                Public_key.of_private_key_exn (Private_key.create ())
                |> Public_key.compress)
          in
          let timed_account pk =
            let account_id = Account_id.create pk Token_id.default in
            let balance = Balance.of_int 100_000_000_000_000 in
            let initial_minimum_balance = Balance.of_int 80_000_000_000 in
            let cliff_time = Global_slot.of_int 2 in
            let cliff_amount = Amount.of_int 5_000_000_000 in
            let vesting_period = Global_slot.of_int 2 in
            let vesting_increment = Amount.of_int 40_000_000_000 in
            Or_error.ok_exn
            @@ Account.create_timed account_id balance ~initial_minimum_balance
                 ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
          in
          let timed_account1 = timed_account receivers.(0) in
          let timed_account2 = timed_account receivers.(1) in
          let fee = 8_000_000_000 in
          let ft1, ft2 =
            let single1 =
              Fee_transfer.Single.create ~receiver_pk:receivers.(0)
                ~fee:(Currency.Fee.of_int fee) ~fee_token:Token_id.default
            in
            let single2 =
              Fee_transfer.Single.create ~receiver_pk:receivers.(1)
                ~fee:(Currency.Fee.of_int fee) ~fee_token:Token_id.default
            in
            ( Fee_transfer.create single1 (Some single2) |> Or_error.ok_exn
            , Fee_transfer.create single1 None |> Or_error.ok_exn )
          in
          let coinbase_with_ft, coinbase_wo_ft =
            let ft =
              Coinbase.Fee_transfer.create ~receiver_pk:receivers.(0)
                ~fee:(Currency.Fee.of_int fee)
            in
            ( Coinbase.create
                ~amount:(Currency.Amount.of_int 10_000_000_000)
                ~receiver:receivers.(1) ~fee_transfer:(Some ft)
              |> Or_error.ok_exn
            , Coinbase.create
                ~amount:(Currency.Amount.of_int 10_000_000_000)
                ~receiver:receivers.(1) ~fee_transfer:None
              |> Or_error.ok_exn )
          in
          let transactions : Transaction.Valid.t list =
            [ Fee_transfer ft1
            ; Fee_transfer ft2
            ; Coinbase coinbase_with_ft
            ; Coinbase coinbase_wo_ft
            ]
          in
          Ledger.with_ledger ~depth:ledger_depth ~f:(fun ledger ->
              List.iter [ timed_account1; timed_account2 ] ~f:(fun acc ->
                  Ledger.create_new_account_exn ledger (Account.identifier acc)
                    acc) ;
              (* well over the vesting period, the timing field shouldn't change*)
              let txn_global_slot = Global_slot.of_int 100 in
              List.iter transactions ~f:(fun txn ->
                  test_transaction ~txn_global_slot ~constraint_constants ledger
                    txn)))
  end )

let%test_module "account timing check" =
  ( module struct
    open Core_kernel
    open Mina_numbers
    open Currency
    open Transaction_validator.For_tests

    (* test that unchecked and checked calculations for timing agree *)

    let checked_min_balance_and_timing account txn_amount txn_global_slot =
      let account = Account.var_of_t account in
      let txn_amount = Amount.var_of_t txn_amount in
      let txn_global_slot = Global_slot.Checked.constant txn_global_slot in
      let%map `Min_balance min_balance, timing =
        Base.check_timing ~balance_check:Tick.Boolean.Assert.is_true
          ~timed_balance_check:Tick.Boolean.Assert.is_true ~account ~txn_amount
          ~txn_global_slot
      in
      (min_balance, timing)

    let make_checked_timing_computation account txn_amount txn_global_slot =
      let%map _min_balance, timing =
        checked_min_balance_and_timing account txn_amount txn_global_slot
      in
      timing

    let make_checked_min_balance_computation account txn_amount txn_global_slot
        =
      let%map min_balance, _timing =
        checked_min_balance_and_timing account txn_amount txn_global_slot
      in
      min_balance

    let snarky_integer_of_bools bools =
      let snarky_bools =
        List.map bools ~f:(fun b ->
            let open Tick.Boolean in
            if b then true_ else false_)
      in
      let bitstring_lsb =
        Bitstring_lib.Bitstring.Lsb_first.of_list snarky_bools
      in
      Snarky_integer.Integer.of_bits ~m:Tick.m bitstring_lsb

    let run_checked_timing_and_compare account txn_amount txn_global_slot
        unchecked_timing unchecked_min_balance =
      let equal_balances_computation =
        let open Snarky_backendless.Checked in
        let%bind checked_timing =
          make_checked_timing_computation account txn_amount txn_global_slot
        in
        (* check agreement of timings produced by checked, unchecked validations *)
        let%bind () =
          as_prover
            As_prover.(
              let%map checked_timing = read Account.Timing.typ checked_timing in
              assert (Account.Timing.equal checked_timing unchecked_timing))
        in
        let%bind checked_min_balance =
          make_checked_min_balance_computation account txn_amount
            txn_global_slot
        in
        let%bind unchecked_min_balance_as_snarky_integer =
          Run.make_checked (fun () ->
              snarky_integer_of_bools (Balance.to_bits unchecked_min_balance))
        in
        let%map equal_balances_checked =
          Run.make_checked (fun () ->
              Snarky_integer.Integer.equal ~m checked_min_balance
                unchecked_min_balance_as_snarky_integer)
        in
        Snarky_backendless.As_prover.read Tick.Boolean.typ
          equal_balances_checked
      in
      let (), equal_balances =
        Or_error.ok_exn @@ Tick.run_and_check equal_balances_computation ()
      in
      equal_balances

    (* confirm the checked computation fails *)
    let checked_timing_should_fail account txn_amount txn_global_slot =
      let checked_timing_computation =
        let%map checked_timing =
          make_checked_timing_computation account txn_amount txn_global_slot
        in
        As_prover.read Account.Timing.typ checked_timing
      in
      Or_error.is_error @@ Tick.run_and_check checked_timing_computation ()

    let%test "before_cliff_time" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 80_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1000 in
      let cliff_amount = Amount.of_int 500_000_000 in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 1_000_000_000 in
      let txn_amount = Currency.Amount.of_int 100_000_000_000 in
      let txn_global_slot = Global_slot.of_int 45 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let timing_with_min_balance =
        validate_timing_with_min_balance ~txn_amount ~txn_global_slot ~account
      in
      match timing_with_min_balance with
      | Ok ((Timed _ as unchecked_timing), `Min_balance unchecked_min_balance)
        ->
          run_checked_timing_and_compare account txn_amount txn_global_slot
            unchecked_timing unchecked_min_balance
      | _ ->
          false

    let%test "positive min balance" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1000 in
      let cliff_amount = Amount.zero in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 100_000_000_000 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let txn_amount = Currency.Amount.of_int 100_000_000_000 in
      let txn_global_slot = Mina_numbers.Global_slot.of_int 1_900 in
      let timing_with_min_balance =
        validate_timing_with_min_balance ~account
          ~txn_amount:(Currency.Amount.of_int 100_000_000_000)
          ~txn_global_slot:(Mina_numbers.Global_slot.of_int 1_900)
      in
      (* we're 900 slots past the cliff, which is 90 vesting periods
          subtract 90 * 100 = 9,000 from init min balance of 10,000 to get 1000
          so we should still be timed
      *)
      match timing_with_min_balance with
      | Ok ((Timed _ as unchecked_timing), `Min_balance unchecked_min_balance)
        ->
          run_checked_timing_and_compare account txn_amount txn_global_slot
            unchecked_timing unchecked_min_balance
      | _ ->
          false

    let%test "curr min balance of zero" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1_000 in
      let cliff_amount = Amount.of_int 900_000_000 in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 100_000_000_000 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let txn_amount = Currency.Amount.of_int 100_000_000_000 in
      let txn_global_slot = Global_slot.of_int 2_000 in
      let timing_with_min_balance =
        validate_timing_with_min_balance ~txn_amount ~txn_global_slot ~account
      in
      (* we're 2_000 - 1_000 = 1_000 slots past the cliff, which is 100 vesting periods
          subtract 100 * 100_000_000_000 = 10_000_000_000_000 from init min balance
          of 10_000_000_000 to get zero, so we should be untimed now
      *)
      match timing_with_min_balance with
      | Ok ((Untimed as unchecked_timing), `Min_balance unchecked_min_balance)
        ->
          run_checked_timing_and_compare account txn_amount txn_global_slot
            unchecked_timing unchecked_min_balance
      | _ ->
          false

    let%test "below calculated min balance" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 10_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1_000 in
      let cliff_amount = Amount.zero in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 100_000_000_000 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let txn_amount = Currency.Amount.of_int 101_000_000_000 in
      let txn_global_slot = Mina_numbers.Global_slot.of_int 1_010 in
      let timing = validate_timing ~txn_amount ~txn_global_slot ~account in
      match timing with
      | Error err ->
          assert (
            Transaction_status.Failure.equal
              (Transaction_logic.timing_error_to_user_command_status err)
              Transaction_status.Failure.Source_minimum_balance_violation ) ;
          checked_timing_should_fail account txn_amount txn_global_slot
      | _ ->
          false

    let%test "insufficient balance" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1000 in
      let cliff_amount = Amount.zero in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 100_000_000_000 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let txn_amount = Currency.Amount.of_int 100_001_000_000_000 in
      let txn_global_slot = Global_slot.of_int 2000_000_000_000 in
      let timing = validate_timing ~txn_amount ~txn_global_slot ~account in
      match timing with
      | Error err ->
          assert (
            Transaction_status.Failure.equal
              (Transaction_logic.timing_error_to_user_command_status err)
              Transaction_status.Failure.Source_insufficient_balance ) ;
          checked_timing_should_fail account txn_amount txn_global_slot
      | _ ->
          false

    let%test "past full vesting" =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1000 in
      let cliff_amount = Amount.zero in
      let vesting_period = Global_slot.of_int 10 in
      let vesting_increment = Amount.of_int 100_000_000_000 in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      (* fully vested, curr min balance = 0, so we can spend the whole balance *)
      let txn_amount = Currency.Amount.of_int 100_000_000_000_000 in
      let txn_global_slot = Global_slot.of_int 3000 in
      let timing_with_min_balance =
        validate_timing_with_min_balance ~txn_amount ~txn_global_slot ~account
      in
      match timing_with_min_balance with
      | Ok ((Untimed as unchecked_timing), `Min_balance unchecked_min_balance)
        ->
          run_checked_timing_and_compare account txn_amount txn_global_slot
            unchecked_timing unchecked_min_balance
      | _ ->
          false

    let make_cliff_amount_test slot =
      let pk = Public_key.Compressed.empty in
      let account_id = Account_id.create pk Token_id.default in
      let balance = Balance.of_int 100_000_000_000_000 in
      let initial_minimum_balance = Balance.of_int 10_000_000_000_000 in
      let cliff_time = Global_slot.of_int 1000 in
      let cliff_amount =
        Balance.to_uint64 initial_minimum_balance |> Amount.of_uint64
      in
      let vesting_period = Global_slot.of_int 1 in
      let vesting_increment = Amount.zero in
      let account =
        Or_error.ok_exn
        @@ Account.create_timed account_id balance ~initial_minimum_balance
             ~cliff_time ~cliff_amount ~vesting_period ~vesting_increment
      in
      let txn_amount = Currency.Amount.of_int 100_000_000_000_000 in
      let txn_global_slot = Global_slot.of_int slot in
      (txn_amount, txn_global_slot, account)

    let%test "before cliff, cliff_amount doesn't affect min balance" =
      let txn_amount, txn_global_slot, account = make_cliff_amount_test 999 in
      let timing = validate_timing ~txn_amount ~txn_global_slot ~account in
      match timing with
      | Error err ->
          assert (
            Transaction_status.Failure.equal
              (Transaction_logic.timing_error_to_user_command_status err)
              Transaction_status.Failure.Source_minimum_balance_violation ) ;
          checked_timing_should_fail account txn_amount txn_global_slot
      | Ok _ ->
          false

    let%test "at exactly cliff time, cliff amount allows spending" =
      let txn_amount, txn_global_slot, account = make_cliff_amount_test 1000 in
      let timing_with_min_balance =
        validate_timing_with_min_balance ~txn_amount ~txn_global_slot ~account
      in
      match timing_with_min_balance with
      | Ok ((Untimed as unchecked_timing), `Min_balance unchecked_min_balance)
        ->
          run_checked_timing_and_compare account txn_amount txn_global_slot
            unchecked_timing unchecked_min_balance
      | _ ->
          false
  end )

let%test_module "transaction_undos" =
  ( module struct
    let constraint_constants =
      Genesis_constants.Constraint_constants.for_unit_tests

    let genesis_constants = Genesis_constants.for_unit_tests

    let consensus_constants =
      Consensus.Constants.create ~constraint_constants
        ~protocol_constants:genesis_constants.protocol

    let state_body =
      let compile_time_genesis =
        Mina_state.Genesis_protocol_state.t
          ~genesis_ledger:Genesis_ledger.(Packed.t for_unit_tests)
          ~genesis_epoch_data:Consensus.Genesis_epoch_data.for_unit_tests
          ~constraint_constants ~consensus_constants
      in
      compile_time_genesis.data |> Mina_state.Protocol_state.body

    let txn_state_view = Mina_state.Protocol_state.Body.view state_body

    let gen_user_commands ~length ledger_init_state =
      let open Quickcheck.Generator.Let_syntax in
      let%map cmds =
        User_command.Valid.Gen.sequence ~length:(length / 2) ~sign_type:`Real
          ledger_init_state
      in
      let cmds = List.map ~f:User_command.forget_check cmds in
      (* Cmds with new receiver accounts *)
      let amount =
        Currency.Fee.scale constraint_constants.account_creation_fee 2
        |> Option.value_exn |> Currency.Amount.of_fee
      in
      let senders =
        Array.filter_map ledger_init_state
          ~f:(fun ((keypair, balance, _, _) as s) ->
            let sender_pk = Public_key.compress keypair.public_key in
            let account_id = Account_id.create sender_pk Token_id.default in
            if
              List.find cmds ~f:(fun cmd ->
                  Account_id.equal (User_command.fee_payer cmd) account_id)
              |> Option.is_some
            then None
            else if Currency.Amount.(balance >= amount) then Some s
            else None)
      in
      let new_cmds =
        let source_accounts =
          List.take (Array.to_list senders) (length - List.length cmds)
        in
        assert (not (List.is_empty source_accounts)) ;
        let new_keys =
          List.init (List.length source_accounts) ~f:(fun _ ->
              Signature_lib.Keypair.create ())
        in
        List.map (List.zip_exn source_accounts new_keys)
          ~f:(fun ((s, _, nonce, _), r) ->
            let sender_pk = Public_key.compress s.public_key in
            let reciever_pk = Public_key.compress r.public_key in
            let fee = Currency.Fee.of_int 10 in
            let payload : Signed_command.Payload.t =
              Signed_command.Payload.create ~fee ~fee_token:Token_id.default
                ~fee_payer_pk:sender_pk ~nonce ~memo:Signed_command_memo.dummy
                ~valid_until:None
                ~body:
                  (Payment
                     { source_pk = sender_pk
                     ; receiver_pk = reciever_pk
                     ; token_id = Token_id.default
                     ; amount
                     })
            in
            let c = Signed_command.sign s payload in
            User_command.Signed_command (Signed_command.forget_check c))
      in
      List.map ~f:(fun c -> Transaction.Command c) (cmds @ new_cmds)

    let gen_fee_transfers ~length ledger_init_state =
      let open Quickcheck.Generator.Let_syntax in
      let count = 3 in
      let new_keys =
        Array.init count ~f:(fun _ -> Signature_lib.Keypair.create ())
      in
      let fee_transfers ?(new_accounts = false) accounts count =
        let max_fee =
          Currency.Fee.scale constraint_constants.account_creation_fee 10
          |> Option.value_exn |> Currency.Fee.to_int
        in
        let min_fee =
          if new_accounts then
            constraint_constants.account_creation_fee |> Currency.Fee.to_int
          else 0
        in
        let%map singles =
          Quickcheck.Generator.list_with_length count
            (Fee_transfer.Single.Gen.with_random_receivers ~keys:accounts
               ~max_fee ~min_fee
               ~token:(Quickcheck.Generator.return Token_id.default))
        in
        One_or_two.group_list singles
        |> List.map ~f:(Fn.compose Or_error.ok_exn Fee_transfer.of_singles)
      in
      let%bind fee_transfer_new_accounts =
        fee_transfers new_keys count ~new_accounts:true
      in
      let remaining = max count (length - count) in
      let%map fee_transfer_existing_accounts =
        fee_transfers
          (Array.init remaining ~f:(fun _ ->
               let keypair, _, _, _ =
                 Array.random_element_exn ledger_init_state
               in
               keypair))
          remaining
      in
      List.map
        ~f:(fun c -> Transaction.Fee_transfer c)
        (fee_transfer_new_accounts @ fee_transfer_existing_accounts)

    let gen_coinbases ~length ledger_init_state =
      let open Quickcheck.Generator.Let_syntax in
      let count = 3 in
      let%bind coinbase_new_accounts =
        Quickcheck.Generator.list_with_length count
          (Quickcheck.Generator.map ~f:fst
             (Coinbase.Gen.gen ~constraint_constants))
      in
      let%map coinbase_existing_accounts =
        let remaining = max count (length - count) in
        let keys =
          Array.init remaining ~f:(fun _ ->
              let keypair, _, _, _ =
                Array.random_element_exn ledger_init_state
              in
              keypair)
        in
        let min_amount =
          Option.value_exn
            (Currency.Fee.scale constraint_constants.account_creation_fee 2)
          |> Currency.Fee.to_int
        in
        let max_amount =
          Currency.Amount.to_int constraint_constants.coinbase_amount
        in
        Quickcheck.Generator.list_with_length remaining
          (Coinbase.Gen.with_random_receivers ~keys ~min_amount ~max_amount
             ~fee_transfer:
               (Coinbase.Fee_transfer.Gen.with_random_receivers ~keys
                  ~min_fee:constraint_constants.account_creation_fee))
      in
      List.map
        ~f:(fun c -> Transaction.Coinbase c)
        (coinbase_new_accounts @ coinbase_existing_accounts)

    let test_undo ledger transaction =
      let merkle_root_before = Ledger.merkle_root ledger in
      let applied_txn =
        Ledger.apply_transaction ~constraint_constants ~txn_state_view ledger
          transaction
        |> Or_error.ok_exn
      in
      let new_mask = Ledger.Mask.create ~depth:(Ledger.depth ledger) () in
      let new_ledger = Ledger.register_mask ledger new_mask in
      let () =
        Ledger.undo ~constraint_constants new_ledger applied_txn
        |> Or_error.ok_exn
      in
      assert (
        Ledger_hash.equal merkle_root_before (Ledger.merkle_root new_ledger) ) ;
      (merkle_root_before, applied_txn)

    let test_undos ledger transactions =
      let res =
        List.fold ~init:[] transactions ~f:(fun acc t ->
            test_undo ledger t :: acc)
      in
      List.iter res ~f:(fun (root_before, u) ->
          let () =
            Ledger.undo ~constraint_constants ledger u |> Or_error.ok_exn
          in
          assert (Ledger_hash.equal (Ledger.merkle_root ledger) root_before))

    let%test_unit "undo_coinbase" =
      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ledger_init_state = Ledger.gen_initial_ledger_state in
        let%map coinbases = gen_coinbases ~length:5 ledger_init_state in
        (ledger_init_state, coinbases)
      in
      Async.Quickcheck.test ~seed:(`Deterministic "coinbase undos")
        ~sexp_of:[%sexp_of: Ledger.init_state * Transaction.t list] ~trials:2
        gen ~f:(fun (ledger_init_state, coinbase_list) ->
          Ledger.with_ephemeral_ledger ~depth:constraint_constants.ledger_depth
            ~f:(fun ledger ->
              Ledger.apply_initial_ledger_state ledger ledger_init_state ;
              test_undos ledger coinbase_list))

    let%test_unit "undo_fee_transfers" =
      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ledger_init_state = Ledger.gen_initial_ledger_state in
        let%map fts = gen_fee_transfers ~length:5 ledger_init_state in
        (ledger_init_state, fts)
      in
      Async.Quickcheck.test ~seed:(`Deterministic "fee-transfer undos")
        ~sexp_of:[%sexp_of: Ledger.init_state * Transaction.t list] ~trials:2
        gen ~f:(fun (ledger_init_state, ft_list) ->
          Ledger.with_ephemeral_ledger ~depth:constraint_constants.ledger_depth
            ~f:(fun ledger ->
              Ledger.apply_initial_ledger_state ledger ledger_init_state ;
              test_undos ledger ft_list))

    let%test_unit "undo_user_commands" =
      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ledger_init_state = Ledger.gen_initial_ledger_state in
        let%map cmds = gen_user_commands ~length:10 ledger_init_state in
        (ledger_init_state, cmds)
      in
      Async.Quickcheck.test ~seed:(`Deterministic "user-command undo")
        ~sexp_of:[%sexp_of: Ledger.init_state * Transaction.t list] ~trials:2
        gen ~f:(fun (ledger_init_state, cmd_list) ->
          Ledger.with_ephemeral_ledger ~depth:constraint_constants.ledger_depth
            ~f:(fun ledger ->
              Ledger.apply_initial_ledger_state ledger ledger_init_state ;
              test_undos ledger cmd_list))

    let%test_unit "undo_all_txns" =
      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ledger_init_state = Ledger.gen_initial_ledger_state in
        let%bind coinbase = gen_coinbases ~length:4 ledger_init_state in
        let%bind fee_transfers =
          gen_fee_transfers ~length:6 ledger_init_state
        in
        let%bind cmds = gen_user_commands ~length:6 ledger_init_state in
        let%map txns =
          let%map txns = Quickcheck_lib.shuffle (fee_transfers @ coinbase) in
          List.take cmds 3 @ List.take txns 5 @ List.drop cmds 3
          @ List.drop txns 5
        in
        (ledger_init_state, txns)
      in
      Async.Quickcheck.test ~seed:(`Deterministic "all-transaction undos")
        ~sexp_of:[%sexp_of: Ledger.init_state * Transaction.t list] ~trials:2
        gen ~f:(fun (ledger_init_state, txn_list) ->
          Ledger.with_ephemeral_ledger ~depth:constraint_constants.ledger_depth
            ~f:(fun ledger ->
              Ledger.apply_initial_ledger_state ledger ledger_init_state ;
              test_undos ledger txn_list))
  end )
