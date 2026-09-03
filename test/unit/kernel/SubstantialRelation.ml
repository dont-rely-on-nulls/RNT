open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)

  let blob_of_string s = Concepts.Blob.blob_of_bytes (Bytes.of_string s)
  let hash_of_string s = blob_of_string s |> Concepts.Hash.hash_of_blob
  let string_of_hash = Concepts.Hash.to_hum_string
  let option_string_of_hash = Option.map string_of_hash

  let check_hash name expected actual =
    check string name (string_of_hash expected) (string_of_hash actual)

  let check_hash_option name expected actual =
    check (option string) name (option_string_of_hash expected) (option_string_of_hash actual)

  let relation_from_handle handle =
    match Protocols.Relation.from handle with
    | Some relation -> relation
    | None -> fail "expected handle to expose a Relation protocol"

  let make_exposes_relation_protocol conn =
    let heading = hash_of_string "heading" in
    let predicate = hash_of_string "predicate" in
    let local_constraints = hash_of_string "local-constraints" in
    let tuple = blob_of_string "tuple/alaric" in
    let handle =
      SR.make conn ~heading ~predicate ~local_constraints () |> Helpers.condition_as_failure
    in
    let relation = relation_from_handle handle in
    let heading' = Protocols.Relation.heading relation |> Helpers.condition_as_failure in
    let predicate' = Protocols.Relation.predicate relation |> Helpers.condition_as_failure in
    let local_constraints' =
      Protocols.Relation.local_constraints relation |> Helpers.condition_as_failure
    in
    let contains = Protocols.Relation.contains relation tuple |> Helpers.condition_as_failure in
    check_hash "heading is exposed through the relation protocol" heading heading';
    check_hash_option "predicate is exposed through the relation protocol" (Some predicate)
      predicate';
    check_hash_option "local constraints are exposed through the relation protocol"
      (Some local_constraints) local_constraints';
    check bool "a newly-created substantial relation has no asserted tuples" false contains

  let assertion_is_immutable_and_persistent conn =
    let heading = hash_of_string "heading" in
    let tuple = blob_of_string "tuple/alaric" in
    let other_tuple = blob_of_string "tuple/gaiseric" in
    let ( original_contains,
          updated_contains,
          other_contains,
          tuple_root_changed,
          stored_address,
          loaded_contains,
          loaded_heading,
          loaded_hash ) =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* original = SR.empty tx ~heading () in
        let original_tuple_root = SR.tuples original in
        let* original_contains = SR.contains_tuple tx original tuple in
        let* updated = SR.assert_tuple tx original tuple in
        let updated_tuple_root = SR.tuples updated in
        let tuple_root_changed =
          not (Concepts.Hash.hash_equals original_tuple_root updated_tuple_root)
        in
        let* updated_contains = SR.contains_tuple tx updated tuple in
        let* other_contains = SR.contains_tuple tx updated other_tuple in
        let* stored_address = SR.store tx updated in
        let* () = S.commit tx in
        let* tx = S.start conn in
        let* loaded = SR.load_value tx stored_address in
        let* loaded_contains = SR.contains_tuple tx loaded tuple in
        let loaded_heading = SR.heading loaded in
        let loaded_hash = SR.hash loaded in
        let* () = S.abort tx in
        Ok
          ( original_contains,
            updated_contains,
            other_contains,
            tuple_root_changed,
            stored_address,
            loaded_contains,
            loaded_heading,
            loaded_hash )
      end
      |> Helpers.condition_as_failure
    in
    check bool "the original relation value remains unchanged" false original_contains;
    check bool "the updated relation value contains the asserted tuple" true updated_contains;
    check bool "unasserted tuples are absent" false other_contains;
    check bool "asserting a tuple changes the tuple root" true tuple_root_changed;
    check bool "stored and loaded relation hashes match" true
      (Concepts.Hash.hash_equals stored_address loaded_hash);
    check bool "loaded relation contains the asserted tuple" true loaded_contains;
    check_hash "loaded relation preserves its heading" heading loaded_heading

  let suite prefix =
    ( "substantial-relation/" ^ prefix,
      [ test_case "relation protocol" `Quick
          (H.with_connection make_exposes_relation_protocol "substantial-relation-test");
        test_case "assertion persistence" `Quick
          (H.with_connection assertion_is_immutable_and_persistent "substantial-relation-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
