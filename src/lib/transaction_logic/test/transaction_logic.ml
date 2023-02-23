open Core_kernel
open Currency
open Mina_base
open Mina_numbers
open Helpers
module Transaction_logic = Mina_transaction_logic.Make (Ledger)

module Zk_result = struct
  type t =
    Transaction_logic.Transaction_applied.Zkapp_command_applied.t
    * Amount.Signed.t
    * bool
  [@@deriving sexp]
end

let constraint_constants =
  { Genesis_constants.Constraint_constants.for_unit_tests with
    account_creation_fee = Fee.of_mina_int_exn 1
  }

type zk_cmd_result =
  Transaction_logic.Transaction_applied.Zkapp_command_applied.t
  * Amount.Signed.t
      [@@deriving sexp]

let balance_to_fee = Fn.compose Amount.to_fee Balance.to_amount

let%test_module "Test transaction logic." =
  ( module struct
    let run_zkapp_cmd ~fee_payer ~fee ~accounts txns =
      let open Result.Let_syntax in
      let unsigned_cmd =
        zkapp_cmd ~noncemap:(noncemap accounts) ~fee:(fee_payer, fee) txns
      in
      let keymap = keymap accounts in
      let cmd =
        Async_unix.Thread_safe.block_on_async_exn (fun () ->
            Zkapp_command_builder.replace_authorizations ~keymap unsigned_cmd )
      in
      let%bind ledger = test_ledger accounts in
      let%map txn, (_, amt) =
        Transaction_logic.apply_zkapp_command_unchecked ~constraint_constants
          ~global_slot:Global_slot.(of_int 120)
          ~state_view:protocol_state ledger cmd
      in
      (txn, amt)

    let%test_unit "Many transactions between distinct accounts." =
      Quickcheck.test
        (let open Quickcheck in
         let open Quickcheck.Generator.Let_syntax in
         let%bind accs_and_txns =
           Generator.list_non_empty gen_account_pair_and_txn
           (* Generating too many transactions makes this test take too much time. *)
           |> Generator.filter ~f:(fun l -> List.length l < 4)
         in
         let (account_pairs, txns) = List.unzip accs_and_txns in
         let accounts = List.concat_map account_pairs ~f:(fun (a, b) -> [a; b]) in
         (* Select a receiver to pay the fee. *)
         let%bind fee_payer = Generator.of_list @@ List.map ~f:snd account_pairs in
         let%map fee = Fee.(gen_incl zero @@ balance_to_fee fee_payer.balance) in
         (fee_payer.pk, fee, accounts, txns))
        ~f:(fun (fee_payer, fee, accounts, txns) ->
          [%test_pred: zk_cmd_result Or_error.t]
            (function
              | Ok (txn, _) ->
                  Transaction_status.(equal txn.command.status Applied)
              | Error _ ->
                  false )
            (run_zkapp_cmd ~fee_payer ~fee ~accounts txns) )
    end )

