(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Mempool_response.t : A MempoolResponse contains all transaction identifiers in the mempool for a particular network_identifier.
 *)

type t = { transaction_identifiers : Transaction_identifier.t list }
[@@deriving yojson { strict = false }, show]

(** A MempoolResponse contains all transaction identifiers in the mempool for a particular network_identifier. *)
let create (transaction_identifiers : Transaction_identifier.t list) : t =
  { transaction_identifiers }
