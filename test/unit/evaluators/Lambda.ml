open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)

  let datum =
    { Concepts.Tuple.type_ = "noun";
      attributes =
        BatMap.String.empty
        |> BatMap.String.add "lemma" (Concepts.Value.String "datum") }

  let reticulare =
    { Concepts.Tuple.type_ = "verb";
      attributes =
        BatMap.String.empty
        |> BatMap.String.add "lemma" (Concepts.Value.String "rēticulāre") }

  let not_a_directory () =
    Concepts.Condition.condition "not-a-directory"
      "A handle was expected to carry the directory protocol and did not" Concepts.Condition.empty

  let not_a_program () =
    Concepts.Condition.condition "not-a-program"
      "A handle was expected to carry the program protocol and did not" Concepts.Condition.empty

  (* Sets up the relations "noun" and "verb", each holding one Latin
     lemma, hands [term] to the lambda evaluator, and drains the cursor
     it returns. Change [term] in the cases below to play with the
     calculus *)
  let evaluate conn term =
    let open Utilities.Result in
    let* tx = S.start conn in
    let* schematics = H.store_schema tx ["lemma"] in
    let singleton tuple =
      let* relation = SR.empty tx ~schematics () in
      SR.assert_tuple tx relation tuple
    in
    let* noun = singleton datum in
    let* verb = singleton reticulare in
    let* () = S.commit tx in
    let* noun = SR.wrap conn noun in
    let* verb = SR.wrap conn verb in
    let root =
      Kernel.Prototype.mixture
        [ Kernel.Prototype.Directory.of_properties
            ["noun", noun; "verb", verb; "lambda", Rnt.Evaluators.Lambda.make ()] ]
    in
    let* directory =
      Protocols.Directory.from root |> Option.to_result ~none:(not_a_directory ())
    in
    let* found = Protocols.Directory.find directory "lambda" in
    let* evaluator = Option.to_result ~none:(not_a_program ()) found in
    let* interpreter =
      Rnt.Evaluators.Lambda.Program.from evaluator
      |> Option.to_result ~none:(not_a_program ())
    in
    let* cursor =
      Rnt.Evaluators.Lambda.(Program.invoke interpreter (Program (term, directory)))
    in
    let* scan = Protocols.Cursor.require cursor in
    let* tuples = Protocols.Cursor.drain scan () in
    Protocols.Handle.release cursor;
    Ok (BatFingerTree.to_list tuples)

  let is lemma tuple =
    Concepts.Hash.hash_equals (Concepts.Tuple.hash tuple) (Concepts.Tuple.hash lemma)

  (* A bare name resolves through the directory, so the relations it
     holds are the outer environment *)
  let a_name_is_a_relation conn =
    let scanned =
      evaluate conn (Rnt.Evaluators.Lambda.Name "noun") |> Helpers.condition_as_failure
    in
    check int "one tuple scanned" 1 (List.length scanned);
    check bool "the tuple that was asserted" true (List.for_all (is datum) scanned)

  (* (\x. x) noun *)
  let identity_applied_to_a_relation conn =
    let open Rnt.Evaluators.Lambda in
    let scanned =
      evaluate conn (Apply (Abstract ("x", Name "x"), Name "noun"))
      |> Helpers.condition_as_failure
    in
    check int "one tuple scanned" 1 (List.length scanned);
    check bool "the tuple that was asserted" true (List.for_all (is datum) scanned)

  (* (\x. \y. x) noun (\z. z), so the argument that wins is the one
     the closure kept *)
  let a_closure_keeps_its_binding conn =
    let open Rnt.Evaluators.Lambda in
    let scanned =
      evaluate conn
        (Apply
           ( Apply (Abstract ("x", Abstract ("y", Name "x")), Name "noun"),
             Abstract ("z", Name "z") ))
      |> Helpers.condition_as_failure
    in
    check int "one tuple scanned" 1 (List.length scanned);
    check bool "the tuple that was asserted" true (List.for_all (is datum) scanned)

  (* The classic conditional, with no conditional in the calculus. A
     boolean is the choice it makes, so [if] is application and both
     branches are relations *)
  let church_conditional conn =
    let open Rnt.Evaluators.Lambda in
    let true_ = Abstract ("then", Abstract ("else", Name "then")) in
    let false_ = Abstract ("then", Abstract ("else", Name "else")) in
    let if_ condition then_ else_ = Apply (Apply (condition, then_), else_) in
    let declining = if_ true_ (Name "noun") (Name "verb") in
    let conjugating = if_ false_ (Name "noun") (Name "verb") in
    let declined = evaluate conn declining |> Helpers.condition_as_failure in
    let conjugated = evaluate conn conjugating |> Helpers.condition_as_failure in
    check int "one tuple on the then branch" 1 (List.length declined);
    check bool "the then branch is the noun" true (List.for_all (is datum) declined);
    check int "one tuple on the else branch" 1 (List.length conjugated);
    check bool "the else branch is the verb" true (List.for_all (is reticulare) conjugated)

  (* A program reducing to an abstraction names nothing to
     enumerate *)
  let an_abstraction_is_not_a_result conn =
    let open Rnt.Evaluators.Lambda in
    match evaluate conn (Abstract ("x", Name "x")) with
    | Error condition ->
       check bool "unapplied abstraction" true
         (String.starts_with ~prefix:"unapplied-abstraction"
            (Concepts.Condition.to_string_hum condition))
    | Ok _ -> fail "an abstraction was enumerated"

  let suite prefix =
    ( "lambda/" ^ prefix,
      [ test_case "a-name-is-a-relation" `Quick
          (H.with_connection a_name_is_a_relation "lambda-name");
        test_case "identity-applied-to-a-relation" `Quick
          (H.with_connection identity_applied_to_a_relation "lambda-identity");
        test_case "a-closure-keeps-its-binding" `Quick
          (H.with_connection a_closure_keeps_its_binding "lambda-closure");
        test_case "church-conditional" `Quick
          (H.with_connection church_conditional "lambda-conditional");
        test_case "an-abstraction-is-not-a-result" `Quick
          (H.with_connection an_abstraction_is_not_a_result "lambda-abstraction") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
