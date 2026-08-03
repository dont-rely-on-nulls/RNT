open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)

  let storage_and_retrieval conn =
    let key = Concepts.Hash.hash_of_value (Concepts.Value.String "value") in
    let value = Concepts.Value.Integer 42 in
    let blob = Concepts.Representation.blob_of_value value in
    let v, v' =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* v = S.get tx key in
        let* () = S.put tx key blob in
        let* v' = S.get tx key in
        Ok Concepts.Representation.(Option.map value_of_blob v, Option.map value_of_blob v')
      end
      |> Helpers.condition_as_failure
    in
    check (option Helpers.value) "`get` before `put` should return no value" None v;
    check (option Helpers.value) "`get` after `put` should return the inserted value" (Some value)
      v'

  let suite prefix =
    ( "storage/" ^ prefix,
      [test_case "storage-and-retrieval" `Quick (H.with_connection storage_and_retrieval "storage-test")] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
