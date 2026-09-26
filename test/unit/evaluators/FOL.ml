open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)

  let alaric =
    { Concepts.Tuple.type_= "employee";
      attributes= BatMap.String.empty |> BatMap.String.add "name" (Concepts.Value.String "Alaric")
    }

  let not_a_directory () =
    Concepts.Condition.condition "not-a-directory"
      "A handle was expected to carry the directory protocol and did not" Concepts.Condition.empty

  let missing name =
    Concepts.Condition.condition "missing" "A name was expected in the directory and was absent"
      Concepts.Condition.("name" |=| Concepts.Value.String name)

  let employee name age =
    { Concepts.Tuple.type_= "employee";
      attributes=
        BatMap.String.of_list ["name", Concepts.Value.String name; "age", Concepts.Value.Integer age]
    }

  let drain result =
    let open Utilities.Result in
    let* enumerable = Protocols.Enumerable.require result in
    let* cursor = Protocols.Enumerable.enumerate enumerable in
    let* scan = Protocols.Cursor.require cursor in
    let* tuples = Protocols.Cursor.drain scan () in
    Protocols.Handle.release cursor;
    Protocols.Handle.release result;
    Ok (BatFingerTree.to_list tuples)

  let scan_a_base_relation conn =
    let scanned =
      begin
        let open Utilities.Result in
        let* employee = H.relation conn ["name"] [alaric] in
        let root =
          Kernel.Prototype.mixture
            [ Kernel.Prototype.Directory.of_properties
                ["employee", employee; "fol", Rnt.Evaluators.FOL.make ()] ]
        in
        let* directory =
          Protocols.Directory.from root |> Option.to_result ~none:(not_a_directory ())
        in
        let* found = Protocols.Directory.find directory "fol" in
        let* evaluator = Option.to_result ~none:(missing "fol") found in
        let* evaluator = Protocols.Evaluator.require evaluator in
        let* result =
          Rnt.Evaluators.FOL.(program (Base employee)) |> Protocols.Evaluator.invoke evaluator
        in
        drain result
      end
      |> Helpers.condition_as_failure
    in
    check int "one tuple scanned" 1 (List.length scanned);
    check bool "the tuple that was asserted" true
      (List.for_all
         (fun tuple ->
           Concepts.Hash.hash_equals (Concepts.Tuple.hash tuple) (Concepts.Tuple.hash alaric) )
         scanned )

  let project_away_an_attribute conn =
    let projected =
      begin
        let open Utilities.Result in
        let* employees =
          H.relation conn ["name"; "age"]
            [employee "Alaric" 42; employee "Alaric" 30; employee "Brunhild" 42]
        in
        let* evaluator = Protocols.Evaluator.require (Rnt.Evaluators.FOL.make ()) in
        let* result =
          Rnt.Evaluators.FOL.(program (Project (Base employees, BatFingerTree.singleton "name")))
          |> Protocols.Evaluator.invoke evaluator
        in
        drain result
      end
      |> Helpers.condition_as_failure
    in
    check
      (list (list (pair string Helpers.value)))
      "each name once, and nothing else"
      [["name", Concepts.Value.String "Alaric"]; ["name", Concepts.Value.String "Brunhild"]]
      ( projected
      |> List.map (fun tuple -> BatMap.String.bindings tuple.Concepts.Tuple.attributes)
      |> List.sort compare )

  let pull_one_tuple_at_a_time () =
    let produced = ref 0 and closed = ref false in
    let description =
      BatMap.String.singleton "value" {Protocols.Schematics.domain= "integer"; provenance= []}
    in
    let rec count ~yield n =
      incr produced;
      yield
        { Concepts.Tuple.type_= "counter";
          attributes= BatMap.String.singleton "value" (Concepts.Value.Integer n) };
      count ~yield (n + 1)
    in
    let source =
      Kernel.EphemeralRelation.instantiate description
        {Kernel.EphemeralRelation.schematics= `Temporary description}
        (fun () -> Ok (Kernel.Generator.cursor_of ~finally:(fun () -> closed := true) (count 0)))
    in
    let first =
      begin
        let open Utilities.Result in
        let* evaluator = Protocols.Evaluator.require (Rnt.Evaluators.FOL.make ()) in
        let* result =
          Rnt.Evaluators.FOL.(program (Project (Base source, BatFingerTree.singleton "value")))
          |> Protocols.Evaluator.invoke evaluator
        in
        let* enumerable = Protocols.Enumerable.require result in
        let* cursor = Protocols.Enumerable.enumerate enumerable in
        let* scan = Protocols.Cursor.require cursor in
        let* first = Protocols.Cursor.next scan in
        Protocols.Handle.release cursor; Protocols.Handle.release result; Ok first
      end
      |> Helpers.condition_as_failure
    in
    check bool "a tuple came through" true (Option.is_some first);
    check int "the source produced only that tuple" 1 !produced;
    check bool "and was closed with its consumer" true !closed

  let suite =
    ( "evaluators/fol",
      [ test_case "scan-a-base-relation" `Quick (H.with_connection scan_a_base_relation "fol-test");
        test_case "project-away-an-attribute" `Quick
          (H.with_connection project_away_an_attribute "fol-test");
        test_case "pull-one-tuple-at-a-time" `Quick pull_one_tuple_at_a_time ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite]
