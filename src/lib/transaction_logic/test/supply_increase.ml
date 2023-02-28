open! Core
open Mina_transaction_logic.Transaction_applied
open Mina_base

let%test_module "supply_increase" =
  ( module struct
    let generator =
      let open Snark_params.Tick in
      let open Quickcheck.Generator.Let_syntax in
      let%bind prev_hash_input_gen = Int.quickcheck_generator in
      let%bind account_id_gen = List.gen_with_length 0 Account_id.gen in
      let%bind payload = Signed_command_payload.gen
      and signer = Mina_base_import.Public_key.gen
      and signature : Signature.t Quickcheck.Generator.t =
        return Signature.dummy
      in
      let%bind data_input : Signed_command.t Quickcheck.Generator.t =
        return
          { Signed_command.Poly.payload
          ; Signed_command.Poly.signer
          ; Signed_command.Poly.signature
          }
      in
      let%bind user_command_input :
          Signed_command.t With_status.t Quickcheck.Generator.t =
        return
          { With_status.data = data_input; status = Transaction_status.Applied }
      in
      let%bind common_input :
          Signed_command_applied.Common.t Quickcheck.Generator.t =
        return
          { Signed_command_applied.Common.user_command = user_command_input }
      in
      let%bind signed_command_input :
          Signed_command_applied.t Quickcheck.Generator.t =
        return
          { Signed_command_applied.common = common_input
          ; body =
              Signed_command_applied.Body.Payment
                { new_accounts = account_id_gen }
          }
      in
      let%bind command_input : Command_applied.t Quickcheck.Generator.t =
        return @@ Command_applied.Signed_command signed_command_input
      in
      let%map varying_input = return @@ Varying.Command command_input
      and previous_hash_input = return @@ Field.of_int prev_hash_input_gen in
      { varying = varying_input; previous_hash = previous_hash_input }

    type signed_amount = Currency.Amount.Signed.t
    [@@deriving equal, sexp, compare]

    let%test_unit "supply_increase_command_input_always_gives_zero_when_no_account_ids"
        =
      Quickcheck.test generator ~f:(fun payload ->
          [%test_eq: signed_amount Or_error.t]
            ( Or_error.return
            @@ Currency.Amount.Signed.create
                 ~magnitude:(Currency.Amount.of_mina_int_exn 0)
                 ~sgn:Sgn.Pos )
            (supply_increase payload) )
  end )
