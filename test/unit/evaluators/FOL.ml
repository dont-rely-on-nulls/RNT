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
        |> BatMap.String.add "name" (Concepts.Value.String "Alaric") }

  let not_a_program () =
    Concepts.Condition.condition "not-a-program"
      "A handle was expected to carry the program protocol and did not" Concepts.Condition.empty

  let scan_a_base_relation conn =
    let scanned =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* relation = SR.empty tx ~schematics:(hash "schema") () in
        let* relation =
          SR.assert_tuple tx relation (Concepts.Tuple.Representation.to_blob alaric)
        in
        let* () = S.commit tx in
        let* employee = SR.wrap conn relation in
        let root =
          Kernel.Prototype.mixture
            [ Kernel.Prototype.Directory.of_properties
                ["employee", employee; "fol", Rnt.Evaluators.FOL.make ()] ]
        in
        let context = Runtime.Context.over ~snapshot:(hash "snapshot") ~root () in
        let* found = Runtime.Context.resolve context "fol" in
        let* evaluator = Option.to_result ~none:(not_a_program ()) found in
        let* interpreter =
          Rnt.Evaluators.FOL.Program.from evaluator
          |> Option.to_result ~none:(not_a_program ())
        in
        let* cursor =
          Rnt.Evaluators.FOL.Program.invoke interpreter
            ~program:(Rnt.Evaluators.FOL.Base "employee") context
        in
        let* scan = Protocols.Cursor.require cursor in
        let* tuples = Protocols.Cursor.drain scan () in
        Protocols.Handle.release cursor;
        Ok (BatFingerTree.to_list tuples)
      end
      |> Helpers.condition_as_failure
    in
    check int "one tuple scanned" 1 (List.length scanned);
    check bool "the tuple that was asserted" true
      (List.for_all
         (fun tuple ->
           Concepts.Hash.hash_equals (Concepts.Tuple.hash tuple) (Concepts.Tuple.hash alaric))
         scanned)

  let suite prefix =
    ( "fol/" ^ prefix,
      [test_case "scan-a-base-relation" `Quick (H.with_connection scan_a_base_relation "fol-test")]
    )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
