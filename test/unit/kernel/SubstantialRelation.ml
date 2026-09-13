open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)

  let hash s =
    Concepts.Blob.blob_of_bytes (Bytes.of_string s) |> Concepts.Hash.hash_of_blob

  let alaric =
    { Concepts.Tuple.type_ = "employee";
      attributes =
        BatMap.String.empty
        |> BatMap.String.add "name" (Concepts.Value.String "Alaric")
        |> BatMap.String.add "age" (Concepts.Value.Integer 42) }

  let assert_and_enumerate conn =
    let tuple = Concepts.Tuple.Representation.to_blob alaric in
    let before, after, enumerated =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* relation = SR.empty tx ~schematics:(hash "schema") () in
        let* before = SR.contains_tuple tx relation tuple in
        let* relation = SR.assert_tuple tx relation tuple in
        let* after = SR.contains_tuple tx relation tuple in
        let* () = S.commit tx in
        let* cursor = SR.enumerate conn relation in
        let* scan = Protocols.Cursor.require cursor in
        let* enumerated = Protocols.Cursor.drain scan () in
        Protocols.Handle.release cursor;
        Ok (before, after, BatFingerTree.to_list enumerated)
      end
      |> Helpers.condition_as_failure
    in
    check bool "absent before assertion" false before;
    check bool "present after assertion" true after;
    check int "one tuple enumerated" 1 (List.length enumerated);
    check bool "the tuple that was asserted" true
      (List.for_all
         (fun tuple ->
           Concepts.Hash.hash_equals (Concepts.Tuple.hash tuple) (Concepts.Tuple.hash alaric))
         enumerated)

  let suite prefix =
    ( "substantial-relation/" ^ prefix,
      [ test_case "assert-and-enumerate" `Quick
          (H.with_connection assert_and_enumerate "substantial-relation-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
