module Branch = Rnt.Concepts.Branch
module Hash = Rnt.Concepts.Hash
module Multigroup = Rnt.Concepts.Multigroup
module Relation = Rnt.Concepts.Relation

let fail_condition c = Alcotest.fail (Rnt.Concepts.Condition.to_string_hum c)
let hash text = Hash.hash_of_bytes (Bytes.of_string text)

let check_hash label expected actual =
  Alcotest.(check bool) label true (Hash.hash_equals expected actual)

let test_branch_round_trips () =
  let expected = Branch.make ~name:"master" ~target:(hash "master-target") in
  match Branch.(expected |> to_bytes |> of_bytes) with
  | Ok actual ->
      Alcotest.(check string) "name" (Branch.name expected) (Branch.name actual);
      check_hash "target" (Branch.target expected) (Branch.target actual)
  | Error c -> fail_condition c

let test_multigroup_round_trips () =
  let expected = Multigroup.make ~name:"public" ~relations:(hash "public-relations") in
  match Multigroup.(expected |> to_bytes |> of_bytes) with
  | Ok actual ->
      Alcotest.(check string) "name" (Multigroup.name expected) (Multigroup.name actual);
      check_hash "relations" (Multigroup.relations expected) (Multigroup.relations actual)
  | Error c -> fail_condition c

let test_relation_round_trips () =
  let schema = Relation.schema_of_list ["tag", "string"; "name", "string"] in
  let expected = Relation.make ~name:"users" ~tuples:(hash "users-tuples") ~schema in
  match Relation.(expected |> to_bytes |> of_bytes) with
  | Ok actual ->
      Alcotest.(check string) "name" (Relation.name expected) (Relation.name actual);
      check_hash "tuples" (Relation.tuples expected) (Relation.tuples actual);
      Alcotest.(check (list (pair string string)))
        "schema"
        (Relation.schema expected |> Relation.schema_to_list)
        (Relation.schema actual |> Relation.schema_to_list)
  | Error c -> fail_condition c

let suites () =
  [ ( "concepts/serialization",
      [ Alcotest.test_case "branch round-trips" `Quick test_branch_round_trips;
        Alcotest.test_case "multigroup round-trips" `Quick test_multigroup_round_trips;
        Alcotest.test_case "relation round-trips" `Quick test_relation_round_trips ] ) ]
