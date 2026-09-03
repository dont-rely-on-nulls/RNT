open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)

  let blob s = Concepts.Blob.blob_of_bytes (Bytes.of_string s)
  let hash s = blob s |> Concepts.Hash.hash_of_blob

  let assert_and_load conn =
    let tuple = blob "tuple/alaric" in
    let original_contains, updated_contains, loaded_contains =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* original = SR.empty tx ~heading:(hash "heading") () in
        let* original_contains = SR.contains_tuple tx original tuple in
        let* updated = SR.assert_tuple tx original tuple in
        let* updated_contains = SR.contains_tuple tx updated tuple in
        let* stored = SR.store tx updated in
        let* () = S.commit tx in
        let* tx = S.start conn in
        let* loaded = SR.load_value tx stored in
        let* loaded_contains = SR.contains_tuple tx loaded tuple in
        let* () = S.abort tx in
        Ok (original_contains, updated_contains, loaded_contains)
      end
      |> Helpers.condition_as_failure
    in
    check bool "original" false original_contains;
    check bool "updated" true updated_contains;
    check bool "loaded" true loaded_contains

  let suite prefix =
    ( "substantial-relation/" ^ prefix,
      [ test_case "assert-and-load" `Quick
          (H.with_connection assert_and_load "substantial-relation-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
