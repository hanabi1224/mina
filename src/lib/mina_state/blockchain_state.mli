open Core_kernel
open Mina_base
open Snark_params.Tick

module Poly : sig
  [%%versioned:
  module Stable : sig
    module V2 : sig
      type ( 'staged_ledger_hash
           , 'snarked_ledger_hash
           , 'local_state
           , 'time
           , 'body_reference )
           t =
        { staged_ledger_hash : 'staged_ledger_hash
        ; genesis_ledger_hash : 'snarked_ledger_hash
        ; registers :
            ('snarked_ledger_hash, unit, 'local_state) Registers.Stable.V1.t
        ; timestamp : 'time
        ; body_reference : 'body_reference
        }
      [@@deriving sexp, fields, equal, compare, hash, yojson, hlist]
    end
  end]
end

module Value : sig
  [%%versioned:
  module Stable : sig
    module V2 : sig
      type t =
        ( Staged_ledger_hash.Stable.V1.t
        , Frozen_ledger_hash.Stable.V1.t
        , Local_state.Stable.V1.t
        , Block_time.Stable.V1.t
        , Consensus.Body_reference.Stable.V1.t )
        Poly.Stable.V2.t
      [@@deriving sexp, equal, compare, hash, yojson]

      val to_latest : t -> t
    end
  end]
end

include
  Snarkable.S
    with type var =
      ( Staged_ledger_hash.var
      , Frozen_ledger_hash.var
      , Local_state.Checked.t
      , Block_time.Checked.t
      , Consensus.Body_reference.var )
      Poly.t
     and type value := Value.t

val staged_ledger_hash :
  ('staged_ledger_hash, _, _, _, _) Poly.t -> 'staged_ledger_hash

val snarked_ledger_hash :
  (_, 'snarked_ledger_hash, _, _, _) Poly.t -> 'snarked_ledger_hash

val genesis_ledger_hash :
  (_, 'snarked_ledger_hash, _, _, _) Poly.t -> 'snarked_ledger_hash

val registers :
     (_, 'snarked_ledger_hash, 'local_state, _, _) Poly.t
  -> ('snarked_ledger_hash, unit, 'local_state) Registers.Stable.V1.t

val timestamp : (_, _, _, 'time, _) Poly.t -> 'time

val body_reference : (_, _, _, _, 'ref) Poly.t -> 'ref

val create_value :
     staged_ledger_hash:Staged_ledger_hash.t
  -> genesis_ledger_hash:Frozen_ledger_hash.t
  -> registers:(Frozen_ledger_hash.t, unit, Local_state.t) Registers.Stable.V1.t
  -> timestamp:Block_time.t
  -> body_reference:Consensus.Body_reference.t
  -> Value.t

val negative_one :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> consensus_constants:Consensus.Constants.t
  -> genesis_ledger_hash:Ledger_hash.t
  -> genesis_body_reference:Consensus.Body_reference.t
  -> Value.t

val genesis :
     constraint_constants:Genesis_constants.Constraint_constants.t
  -> consensus_constants:Consensus.Constants.t
  -> genesis_ledger_hash:Ledger_hash.t
  -> genesis_body_reference:Consensus.Body_reference.t
  -> Value.t

val set_timestamp :
     ('staged_ledger_hash, 'lh, 'ls, 'time, 'body_ref) Poly.t
  -> 'time
  -> ('staged_ledger_hash, 'lh, 'ls, 'time, 'body_ref) Poly.t

val to_input : Value.t -> Field.t Random_oracle.Input.Chunked.t

val var_to_input : var -> Field.Var.t Random_oracle.Input.Chunked.t

type display = (string, string, Local_state.display, string, string) Poly.t
[@@deriving yojson]

val display : Value.t -> display
