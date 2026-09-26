open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)

  let alaric =
    { Concepts.Tuple.type_= "employee";
      attributes=
        BatMap.String.empty
        |> BatMap.String.add "name" (Concepts.Value.String "Alaric")
        |> BatMap.String.add "age" (Concepts.Value.Integer 42) }

  let contains relation tuple =
    let open Utilities.Result in
    let* relation = Protocols.Relation.require relation in
    Protocols.Relation.contains relation tuple

  let enumerate relation =
    let open Utilities.Result in
    let* enumerable = Protocols.Enumerable.require relation in
    let* cursor = Protocols.Enumerable.enumerate enumerable in
    let* scan = Protocols.Cursor.require cursor in
    let* enumerated = Protocols.Cursor.drain scan () in
    Protocols.Handle.release cursor;
    Ok (BatFingerTree.to_list enumerated)

  let contain_and_enumerate conn =
    let absent, present, enumerated =
      begin
        let open Utilities.Result in
        let* schematics =
          H.SI.with_transaction conn (fun tx -> H.store_schema tx ["name"; "age"])
        in
        let* empty = SR.instantiate conn ~schematics in
        let* absent = contains empty alaric in
        let* holding = H.relation conn ["name"; "age"] [alaric] in
        let* present = contains holding alaric in
        let* enumerated = enumerate holding in
        Ok (absent, present, enumerated)
      end
      |> Helpers.condition_as_failure
    in
    check bool "absent from an empty relation" false absent;
    check bool "present in a relation holding it" true present;
    check int "one tuple enumerated" 1 (List.length enumerated);
    check bool "the tuple that was asserted" true
      (List.for_all
         (fun tuple ->
           Concepts.Hash.hash_equals (Concepts.Tuple.hash tuple) (Concepts.Tuple.hash alaric) )
         enumerated )

  let suite =
    ( "kernel/substantial-relation",
      [ test_case "contain-and-enumerate" `Quick
          (H.with_connection contain_and_enumerate "substantial-relation-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite]
