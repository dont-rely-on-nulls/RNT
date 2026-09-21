open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module SR = Rnt.Kernel.SubstantialRelation.Make (S)
  module SI = Rnt.Kernel.Storage.Make (S)
  module Constraint = Rnt.Evaluators.Constraint

  let not_a_program () =
    Concepts.Condition.condition "not-a-program"
      "A handle was expected to carry the program protocol and did not" Concepts.Condition.empty

  let named type_ name =
    { Concepts.Tuple.type_;
      attributes = BatMap.String.singleton "name" (Concepts.Value.String name) }

  let holding conn tuples =
    let open Utilities.Result in
    let* tx = S.start conn in
    let schema = Concepts.Encoding.Bencode.(Dict ["name", String "string"]) in
    let* schematics = SI.store_blob tx (Concepts.Encoding.Bencode.to_blob schema) in
    let* relation = SR.empty tx ~schematics () in
    let* relation =
      List.fold_left
        (fun acc tuple ->
          let* relation = acc in
          SR.assert_tuple tx relation tuple)
        (Ok relation) tuples
    in
    let* () = S.commit tx in
    SR.wrap conn relation

  let membership name binding =
    {Constraint.target = Kernel.Path.(name @/ this); binding = BatMap.String.of_list binding}

  (* NOT EXISTS (worker w, manager m WHERE w.name = m.name) *)
  let no_worker_is_a_manager () =
    Constraint.declare ~name:"no-worker-is-a-manager"
      (Constraint.Not
         (Constraint.Exists
            { Constraint.quantifiers =
                [ membership "worker" ["name", Constraint.Var "w"];
                  membership "manager" ["name", Constraint.Var "m"] ];
              body = Constraint.Eq {left = Constraint.Var "w"; right = Constraint.Var "m"} }))

  let checking relations =
    let open Utilities.Result in
    let state =
      Kernel.Prototype.mixture
        [ Kernel.Prototype.Directory.of_properties
            (relations @ ["constraint", Constraint.make ()]) ]
    in
    let* checker = Kernel.Path.(lookup state ("constraint" @/ this)) in
    let* interpreter =
      Constraint.Program.from checker |> Option.to_result ~none:(not_a_program ())
    in
    Ok (interpreter, state)

  let a_constraint_across_relations conn =
    let apart, together =
      begin
        let open Utilities.Result in
        let* constrains = no_worker_is_a_manager () in
        let* worker = holding conn [named "worker" "Alaric"] in
        let* elsewhere = holding conn [named "manager" "Brunhilda"] in
        let* interpreter, state = checking ["worker", worker; "manager", elsewhere] in
        let* apart = Constraint.satisfied interpreter constrains state in
        let* promoted = holding conn [named "manager" "Alaric"] in
        let* interpreter, state = checking ["worker", worker; "manager", promoted] in
        let* together = Constraint.satisfied interpreter constrains state in
        Ok (apart, together)
      end
      |> Helpers.condition_as_failure
    in
    check bool "no worker is a manager" true apart;
    check bool "a worker was made a manager" false together

  let suite prefix =
    ( "constraint/" ^ prefix,
      [ test_case "a-constraint-across-relations" `Quick
          (H.with_connection a_constraint_across_relations "constraint-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
