open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)

  let storage_and_retrieval conn =
    let key = Concepts.Value.String "value" |> Concepts.Encoding.blob_of_value |> Concepts.Hash.hash_of_blob in
    let value = Concepts.Value.Integer 42 in
    let blob = Concepts.Encoding.blob_of_value value in
    let before, in_transaction, after =
      begin
        let open Utilities.Result in
        let rec repeat_reads remaining =
          if remaining = 0 then Ok ()
          else
            let* _ = S.read conn (S.Hash key) in
            repeat_reads (remaining - 1)
        in
        let* before = S.read conn (S.Hash key) in
        let* tx = S.start conn in
        let* () = S.put tx (S.Hash key) blob in
        let* in_transaction = S.get tx (S.Hash key) in
        let* () = S.commit tx in
        let* () = repeat_reads 256 in
        let* after = S.read conn (S.Hash key) in
        Ok
          Concepts.Encoding.
            ( Option.map value_of_blob before,
              Option.map value_of_blob in_transaction,
              Option.map value_of_blob after )
      end
      |> Helpers.condition_as_failure
    in
    check (option Helpers.value) "`read` before `put` should return no value" None before;
    check (option Helpers.value) "`get` should observe a transactional `put`" (Some value)
      in_transaction;
    check (option Helpers.value) "`read` after commit should return the inserted value" (Some value)
      after

  let suite prefix =
    ( "storage/" ^ prefix,
      [test_case "storage-and-retrieval" `Quick (H.with_connection storage_and_retrieval "storage-test")] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
