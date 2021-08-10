[%%import "/src/config.mlh"]

open Core_kernel

[%%ifdef consensus_mechanism]

open Snark_params.Tick
open Signature_lib
module Mina_numbers = Mina_numbers

[%%else]

open Signature_lib_nonconsensus
module Mina_numbers = Mina_numbers_nonconsensus.Mina_numbers
module Currency = Currency_nonconsensus.Currency
module Random_oracle = Random_oracle_nonconsensus.Random_oracle

[%%endif]

module Impl = Pickles.Impls.Step
open Mina_numbers
open Currency
open Pickles_types
module Digest = Random_oracle.Digest

module type Type = sig
  type t
end

module Update = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ( 'state_element
             , 'pk
             , 'vk
             , 'perms
             , 'snapp_uri
             , 'token_symbol
             , 'timing )
             t =
          { app_state : 'state_element Snapp_state.V.Stable.V1.t
          ; delegate : 'pk
          ; verification_key : 'vk
          ; permissions : 'perms
          ; snapp_uri : 'snapp_uri
          ; token_symbol : 'token_symbol
          ; timing : 'timing
          }
        [@@deriving compare, equal, sexp, hash, yojson, hlist]
      end
    end]
  end

  module Timing_info = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          { initial_minimum_balance : Balance.Stable.V1.t
          ; cliff_time : Global_slot.Stable.V1.t
          ; cliff_amount : Amount.Stable.V1.t
          ; vesting_period : Global_slot.Stable.V1.t
          ; vesting_increment : Amount.Stable.V1.t
          }
        [@@deriving compare, equal, sexp, hash, yojson, hlist]

        let to_latest = Fn.id
      end
    end]

    type value = t

    let to_input (t : t) =
      List.reduce_exn ~f:Random_oracle_input.append
        [ Balance.to_input t.initial_minimum_balance
        ; Global_slot.to_input t.cliff_time
        ; Amount.to_input t.cliff_amount
        ; Global_slot.to_input t.vesting_period
        ; Amount.to_input t.vesting_increment
        ]

    let dummy =
      let slot_unused = Global_slot.zero in
      let balance_unused = Balance.zero in
      let amount_unused = Amount.zero in
      { initial_minimum_balance = balance_unused
      ; cliff_time = slot_unused
      ; cliff_amount = amount_unused
      ; vesting_period = slot_unused
      ; vesting_increment = amount_unused
      }

    module Checked = struct
      type t =
        { initial_minimum_balance : Balance.Checked.t
        ; cliff_time : Global_slot.Checked.t
        ; cliff_amount : Amount.Checked.t
        ; vesting_period : Global_slot.Checked.t
        ; vesting_increment : Amount.Checked.t
        }
      [@@deriving hlist]

      let constant (t : value) : t =
        { initial_minimum_balance = Balance.var_of_t t.initial_minimum_balance
        ; cliff_time = Global_slot.Checked.constant t.cliff_time
        ; cliff_amount = Amount.var_of_t t.cliff_amount
        ; vesting_period = Global_slot.Checked.constant t.vesting_period
        ; vesting_increment = Amount.var_of_t t.vesting_increment
        }

      let to_input
          ({ initial_minimum_balance
           ; cliff_time
           ; cliff_amount
           ; vesting_period
           ; vesting_increment
           } :
            t) =
        List.reduce_exn ~f:Random_oracle_input.append
          [ Balance.var_to_input initial_minimum_balance
          ; Snark_params.Tick.Run.run_checked
              (Global_slot.Checked.to_input cliff_time)
          ; Amount.var_to_input cliff_amount
          ; Snark_params.Tick.Run.run_checked
              (Global_slot.Checked.to_input vesting_period)
          ; Amount.var_to_input vesting_increment
          ]
    end

    let typ : (Checked.t, t) Typ.t =
      Typ.of_hlistable
        [ Balance.typ
        ; Global_slot.typ
        ; Amount.typ
        ; Global_slot.typ
        ; Amount.typ
        ]
        ~var_to_hlist:Checked.to_hlist ~var_of_hlist:Checked.of_hlist
        ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
  end

  open Snapp_basic

  [%%versioned
  module Stable = struct
    module V1 = struct
      (* TODO: Have to check that the public key is not = Public_key.Compressed.empty here.  *)
      type t =
        ( F.Stable.V1.t Set_or_keep.Stable.V1.t
        , Public_key.Compressed.Stable.V1.t Set_or_keep.Stable.V1.t
        , ( Pickles.Side_loaded.Verification_key.Stable.V1.t
          , F.Stable.V1.t )
          With_hash.Stable.V1.t
          Set_or_keep.Stable.V1.t
        , Permissions.Stable.V1.t Set_or_keep.Stable.V1.t
        , string Set_or_keep.Stable.V1.t
        , Account.Token_symbol.Stable.V1.t Set_or_keep.Stable.V1.t
        , Timing_info.Stable.V1.t Set_or_keep.Stable.V1.t )
        Poly.Stable.V1.t
      [@@deriving compare, equal, sexp, hash, yojson]

      let to_latest = Fn.id
    end
  end]

  module Checked = struct
    open Pickles.Impls.Step

    type t =
      ( Field.t Set_or_keep.Checked.t
      , Public_key.Compressed.var Set_or_keep.Checked.t
      , Field.t Set_or_keep.Checked.t
      , Permissions.Checked.t Set_or_keep.Checked.t
      , string Data_as_hash.t Set_or_keep.Checked.t
      , Account.Token_symbol.var Set_or_keep.Checked.t
      , Timing_info.Checked.t Set_or_keep.Checked.t )
      Poly.t

    let to_input
        ({ app_state
         ; delegate
         ; verification_key
         ; permissions
         ; snapp_uri
         ; token_symbol
         ; timing
         } :
          t) =
      let open Random_oracle_input in
      List.reduce_exn ~f:append
        [ Snapp_state.to_input app_state
            ~f:(Set_or_keep.Checked.to_input ~f:field)
        ; Set_or_keep.Checked.to_input delegate
            ~f:Public_key.Compressed.Checked.to_input
        ; Set_or_keep.Checked.to_input verification_key ~f:field
        ; Set_or_keep.Checked.to_input permissions
            ~f:Permissions.Checked.to_input
        ; Set_or_keep.Checked.to_input snapp_uri ~f:Data_as_hash.to_input
        ; Set_or_keep.Checked.to_input token_symbol
            ~f:Account.Token_symbol.var_to_input
        ; Set_or_keep.Checked.to_input timing ~f:Timing_info.Checked.to_input
        ]
  end

  let noop : t =
    { app_state =
        Vector.init Snapp_state.Max_state_size.n ~f:(fun _ -> Set_or_keep.Keep)
    ; delegate = Keep
    ; verification_key = Keep
    ; permissions = Keep
    ; snapp_uri = Keep
    ; token_symbol = Keep
    ; timing = Keep
    }

  let dummy = noop

  let to_input
      ({ app_state
       ; delegate
       ; verification_key
       ; permissions
       ; snapp_uri
       ; token_symbol
       ; timing
       } :
        t) =
    let open Random_oracle_input in
    List.reduce_exn ~f:append
      [ Snapp_state.to_input app_state
          ~f:(Set_or_keep.to_input ~dummy:Field.zero ~f:field)
      ; Set_or_keep.to_input delegate
          ~dummy:(Snapp_predicate.Eq_data.Tc.public_key ()).default
          ~f:Public_key.Compressed.to_input
      ; Set_or_keep.to_input
          (Set_or_keep.map verification_key ~f:With_hash.hash)
          ~dummy:Field.zero ~f:field
      ; Set_or_keep.to_input permissions ~dummy:Permissions.user_default
          ~f:Permissions.to_input
      ; Set_or_keep.to_input
          (Set_or_keep.map ~f:Account.hash_snapp_uri snapp_uri)
          ~dummy:(Account.hash_snapp_uri_opt None)
          ~f:field
      ; Set_or_keep.to_input token_symbol ~dummy:Account.Token_symbol.default
          ~f:Account.Token_symbol.to_input
      ; Set_or_keep.to_input timing ~dummy:Timing_info.dummy
          ~f:Timing_info.to_input
      ]

  let typ () : (Checked.t, t) Typ.t =
    let open Poly in
    let open Pickles.Impls.Step in
    Typ.of_hlistable
      [ Snapp_state.typ (Set_or_keep.typ ~dummy:Field.Constant.zero Field.typ)
      ; Set_or_keep.typ ~dummy:Public_key.Compressed.empty
          Public_key.Compressed.typ
      ; Set_or_keep.typ ~dummy:Field.Constant.zero Field.typ
        |> Typ.transport
             ~there:(Set_or_keep.map ~f:With_hash.hash)
             ~back:(Set_or_keep.map ~f:(fun _ -> failwith "vk typ"))
      ; Set_or_keep.typ ~dummy:Permissions.user_default Permissions.typ
      ; (* We have to do this unfortunate dance to provide a dummy value. *)
        Set_or_keep.typ ~dummy:None
          (Data_as_hash.optional_typ ~hash:Account.hash_snapp_uri
             ~non_preimage:(Account.hash_snapp_uri_opt None)
             ~dummy_value:"")
        |> Typ.transport
             ~there:(Set_or_keep.map ~f:Option.some)
             ~back:(Set_or_keep.map ~f:(fun x -> Option.value_exn x))
      ; Set_or_keep.typ ~dummy:Account.Token_symbol.default
          Account.Token_symbol.typ
      ; Set_or_keep.typ ~dummy:Timing_info.dummy Timing_info.typ
      ]
      ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
      ~value_of_hlist:of_hlist
end

module Events = Snapp_account.Events
module Rollup_events = Snapp_account.Rollup_events

module Body = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ( 'pk
             , 'update
             , 'token_id
             , 'signed_amount
             , 'events
             , 'call_data
             , 'int )
             t =
          { pk : 'pk
          ; update : 'update
          ; token_id : 'token_id
          ; delta : 'signed_amount
          ; events : 'events
          ; rollup_events : 'events
          ; call_data : 'call_data
          ; depth : 'int
          }
        [@@deriving hlist, sexp, equal, yojson, hash, compare]
      end
    end]
  end

  (* Why isn't this derived automatically? *)
  let hash_fold_array f init x = Array.fold ~init ~f x

  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        ( Public_key.Compressed.Stable.V1.t
        , Update.Stable.V1.t
        , Token_id.Stable.V1.t
        , (Amount.Stable.V1.t, Sgn.Stable.V1.t) Signed_poly.Stable.V1.t
        , Pickles.Backend.Tick.Field.Stable.V1.t array list
        , Pickles.Backend.Tick.Field.Stable.V1.t (* Opaque to txn logic *)
        , int )
        Poly.Stable.V1.t
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]

  module Checked = struct
    type t =
      ( Public_key.Compressed.var
      , Update.Checked.t
      , Token_id.Checked.t
      , Amount.Signed.var
      , Events.var
      , Field.Var.t
      , int As_prover.Ref.t )
      Poly.t

    let to_input
        ({ pk
         ; update
         ; token_id
         ; delta
         ; events
         ; rollup_events
         ; call_data
         ; depth = _depth (* ignored *)
         } :
          t) =
      List.reduce_exn ~f:Random_oracle_input.append
        [ Public_key.Compressed.Checked.to_input pk
        ; Update.Checked.to_input update
        ; Impl.run_checked (Token_id.Checked.to_input token_id)
        ; Amount.Signed.Checked.to_input delta
        ; Events.var_to_input events
        ; Events.var_to_input rollup_events
        ; Random_oracle_input.field call_data
        ]

    let digest (t : t) =
      Random_oracle.Checked.(
        hash ~init:Hash_prefix.snapp_body (pack_input (to_input t)))
  end

  let typ () : (Checked.t, t) Typ.t =
    let open Poly in
    Typ.of_hlistable
      [ Public_key.Compressed.typ
      ; Update.typ ()
      ; Token_id.typ
      ; Amount.Signed.typ
      ; Events.typ
      ; Events.typ
      ; Field.typ
      ; Typ.Internal.ref ()
      ]
      ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
      ~value_of_hlist:of_hlist

  let dummy : t =
    { pk = Public_key.Compressed.empty
    ; update = Update.dummy
    ; token_id = Token_id.default
    ; delta = Amount.Signed.zero
    ; events = []
    ; rollup_events = []
    ; call_data = Field.zero
    ; depth = 0
    }

  let to_input
      ({ pk
       ; update
       ; token_id
       ; delta
       ; events
       ; rollup_events
       ; call_data
       ; depth = _ (* ignored *)
       } :
        t) =
    List.reduce_exn ~f:Random_oracle_input.append
      [ Public_key.Compressed.to_input pk
      ; Update.to_input update
      ; Token_id.to_input token_id
      ; Amount.Signed.to_input delta
      ; Events.to_input events
      ; Events.to_input rollup_events
      ; Random_oracle_input.field call_data
      ]

  let digest (t : t) =
    Random_oracle.(hash ~init:Hash_prefix.snapp_body (pack_input (to_input t)))

  module Digested = struct
    type t = Random_oracle.Digest.t

    module Checked = struct
      type t = Random_oracle.Checked.Digest.t
    end
  end
end

module Predicate = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
        | Full of Snapp_predicate.Account.Stable.V2.t
        | Nonce of Account.Nonce.Stable.V1.t
        | Accept
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]

  let accept = lazy Random_oracle.(digest (salt "MinaPartyAccept"))

  let digest (t : t) =
    let digest x =
      Random_oracle.(
        hash ~init:Hash_prefix_states.party_predicate (pack_input x))
    in
    match t with
    | Full a ->
        Snapp_predicate.Account.to_input a |> digest
    | Nonce n ->
        Account.Nonce.to_input n |> digest
    | Accept ->
        Lazy.force accept

  module Checked = struct
    type t =
      | Nonce_or_accept of
          { nonce : Account.Nonce.Checked.t; accept : Boolean.var }
      | Full of Snapp_predicate.Account.Checked.t

    let digest (t : t) =
      let digest x =
        Random_oracle.Checked.(
          hash ~init:Hash_prefix_states.party_predicate (pack_input x))
      in
      match t with
      | Full a ->
          Snapp_predicate.Account.Checked.to_input a |> digest
      | Nonce_or_accept { nonce; accept = b } ->
          let open Impl in
          Field.(
            if_ b
              ~then_:(constant (Lazy.force accept))
              ~else_:
                (digest (run_checked (Account.Nonce.Checked.to_input nonce))))
  end

  let typ () : (Snapp_predicate.Account.Checked.t, t) Typ.t =
    Typ.transport
      (Snapp_predicate.Account.typ ())
      ~there:(function
        | Full s ->
            s
        | Nonce n ->
            { Snapp_predicate.Account.accept with
              nonce = Check { lower = n; upper = n }
            }
        | Accept ->
            Snapp_predicate.Account.accept)
      ~back:(fun s -> Full s)
end

module Predicated = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ('body, 'predicate) t = { body : 'body; predicate : 'predicate }
        [@@deriving hlist, sexp, equal, yojson, hash, compare]
      end
    end]
  end

  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = (Body.Stable.V1.t, Predicate.Stable.V1.t) Poly.Stable.V1.t
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]

  let to_input ({ body; predicate } : t) =
    List.reduce_exn ~f:Random_oracle_input.append
      [ Body.to_input body
      ; Random_oracle_input.field (Predicate.digest predicate)
      ]

  let digest (t : t) =
    Random_oracle.(hash ~init:Hash_prefix.party (pack_input (to_input t)))

  let typ () : (_, t) Typ.t =
    let open Poly in
    Typ.of_hlistable
      [ Body.typ (); Predicate.typ () ]
      ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
      ~value_of_hlist:of_hlist

  module Checked = struct
    type t = (Body.Checked.t, Predicate.Checked.t) Poly.t

    let to_input ({ body; predicate } : t) =
      List.reduce_exn ~f:Random_oracle_input.append
        [ Body.Checked.to_input body
        ; Random_oracle_input.field (Predicate.Checked.digest predicate)
        ]

    let digest (t : t) =
      Random_oracle.Checked.(
        hash ~init:Hash_prefix.party (pack_input (to_input t)))
  end

  module Proved = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t =
          ( Body.Stable.V1.t
          , Snapp_predicate.Account.Stable.V1.t )
          Poly.Stable.V1.t
        [@@deriving sexp, equal, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Digested = struct
      type t = (Body.Digested.t, Snapp_predicate.Digested.t) Poly.t

      module Checked = struct
        type t = (Body.Digested.Checked.t, Field.Var.t) Poly.t
      end
    end

    module Checked = struct
      type t = (Body.Checked.t, Snapp_predicate.Account.Checked.t) Poly.t
    end
  end

  module Signed = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = (Body.Stable.V1.t, Account_nonce.Stable.V1.t) Poly.Stable.V1.t
        [@@deriving sexp, equal, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    module Checked = struct
      type t = (Body.Checked.t, Account_nonce.Checked.t) Poly.t
    end

    let dummy : t = { body = Body.dummy; predicate = Account_nonce.zero }
  end

  module Empty = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type t = (Body.Stable.V1.t, unit) Poly.Stable.V1.t
        [@@deriving sexp, equal, yojson, hash, compare]

        let to_latest = Fn.id
      end
    end]

    let dummy : t = { body = Body.dummy; predicate = () }

    let create body : t = { body; predicate = () }
  end

  let of_signed ({ body; predicate } : Signed.t) : t =
    { body; predicate = Nonce predicate }
end

module Poly (Data : Type) (Auth : Type) = struct
  type t = { data : Data.t; authorization : Auth.t }
end

module Proved = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t =
            Poly(Predicated.Proved.Stable.V1)
              (Pickles.Side_loaded.Proof.Stable.V1)
            .t =
        { data : Predicated.Proved.Stable.V1.t
        ; authorization : Pickles.Side_loaded.Proof.Stable.V1.t
        }
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]
end

module Signed = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Poly(Predicated.Signed.Stable.V1)(Signature.Stable.V1).t =
        { data : Predicated.Signed.Stable.V1.t
        ; authorization : Signature.Stable.V1.t
        }
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]

  let account_id (t : t) : Account_id.t =
    Account_id.create t.data.body.pk t.data.body.token_id
end

module Empty = struct
  [%%versioned
  module Stable = struct
    module V1 = struct
      type t = Poly(Predicated.Empty.Stable.V1)(Unit.Stable.V1).t =
        { data : Predicated.Empty.Stable.V1.t; authorization : unit }
      [@@deriving sexp, equal, yojson, hash, compare]

      let to_latest = Fn.id
    end
  end]
end

[%%versioned
module Stable = struct
  module V1 = struct
    type t = Poly(Predicated.Stable.V1)(Control.Stable.V1).t =
      { data : Predicated.Stable.V1.t; authorization : Control.Stable.V1.t }
    [@@deriving sexp, equal, yojson, hash, compare]

    let to_latest = Fn.id
  end
end]

let account_id (t : t) : Account_id.t =
  Account_id.create t.data.body.pk t.data.body.token_id

let of_signed ({ data; authorization } : Signed.t) : t =
  { authorization = Signature authorization; data = Predicated.of_signed data }