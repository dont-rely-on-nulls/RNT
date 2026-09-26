open Alcotest
module Concepts = Rnt.Concepts
module Protocols = Rnt.Protocols

(* A derivation over a fixed set of members. It reads nothing and
   computes nothing, so what the tests observe is the kernel object
   rather than any particular evaluator. *)
module Derivation = struct
  type plan = {name: string; members: Concepts.Tuple.t list; declared: Concepts.Mode.t}

  let identity {name; _} = Concepts.Hash.hash_of_bytes (Bytes.of_string name)

  let describe _ =
    Ok
      (BatMap.String.singleton "value"
         { Protocols.Schematics.domain= "integer";
           provenance= [{Protocols.Schematics.source= ["example"]; attribute= "value"}] } )

  let modes {declared; _} = Ok declared

  let generate {members; _} binding =
    Ok
      (Rnt.Kernel.Generator.cursor_of (fun ~yield ->
           List.iter
             (fun member -> if Protocols.Generative.satisfies binding member then yield member)
             members;
           Ok () ) )
end

module Derived = Rnt.Kernel.EphemeralRelation.Make (Derivation)

let member n =
  { Concepts.Tuple.type_= "example";
    attributes= BatMap.String.singleton "value" (Concepts.Value.Integer n) }

let plan_over cardinality =
  { Derivation.name= "the-derivation";
    members= [member 1; member 2; member 3];
    declared=
      Concepts.Mode.of_list
        [Concepts.Mode.enumerable cardinality; Concepts.Mode.decides_when ["value"]] }

let derive plan = Derived.derive plan |> Helpers.condition_as_failure

let values tuples =
  BatFingerTree.to_list tuples
  |> List.filter_map (fun tuple ->
      match BatMap.String.find_opt "value" tuple.Concepts.Tuple.attributes with
      | Some (Concepts.Value.Integer n) -> Some n
      | _ -> None )
  |> List.sort compare

let commit = Concepts.Hash.hash_of_bytes (Bytes.of_string "a-commit")

let identity_is_the_derivation () =
  let plan = plan_over Concepts.Cardinality.Finite in
  check bool "unpinned, the identity of the plan" true
    (Concepts.Hash.hash_equals (Derived.identity plan) (Derivation.identity plan));
  check bool "pinned to a commit, another identity" false
    (Concepts.Hash.hash_equals (Derived.identity plan) (Derived.identity ~pinned:commit plan));
  check bool "the same pin twice is the same identity" true
    (Concepts.Hash.hash_equals
       (Derived.identity ~pinned:commit plan)
       (Derived.identity ~pinned:commit plan) )

let an_exhaustible_derivation_enumerates () =
  let derived = derive (plan_over Concepts.Cardinality.Finite) in
  let enumerated =
    begin
      let open Rnt.Utilities.Result in
      let* enumerable = Protocols.Enumerable.require derived in
      let* cursor = Protocols.Enumerable.enumerate enumerable in
      let* scan = Protocols.Cursor.require cursor in
      let* tuples = Protocols.Cursor.drain scan () in
      Protocols.Handle.release cursor;
      Ok (values tuples)
    end
    |> Helpers.condition_as_failure
  in
  check (list int) "every member" [1; 2; 3] enumerated

let a_countable_derivation_decides_only () =
  let derived = derive (plan_over Concepts.Cardinality.Countable) in
  let holds, rejects =
    begin
      let open Rnt.Utilities.Result in
      let* relation = Protocols.Relation.require derived in
      let* holds = Protocols.Relation.contains relation (member 2) in
      let* rejects = Protocols.Relation.contains relation (member 9) in
      Ok (holds, rejects)
    end
    |> Helpers.condition_as_failure
  in
  check bool "no enumeration is offered" false (Option.is_some (Protocols.Enumerable.from derived));
  check bool "membership is still decided" true holds;
  check bool "and still refused" false rejects

let a_derivation_describes_itself () =
  let derived = derive (plan_over Concepts.Cardinality.Finite) in
  let described =
    begin
      let open Rnt.Utilities.Result in
      let* schematics = Protocols.Handle.require Protocols.Schematics.from derived in
      Protocols.Schematics.describe schematics
    end
    |> Helpers.condition_as_failure
  in
  match described with
  | Protocols.Schematics.Relation description ->
      check (list string) "the attributes of the result" ["value"]
        (BatMap.String.keys description |> BatList.of_enum);
      check (list string) "and where each was drawn from" ["example/value"]
        ( BatMap.String.values description
        |> BatList.of_enum
        |> List.concat_map (fun attribute ->
            attribute.Protocols.Schematics.provenance
            |> List.map (fun origin ->
                String.concat "/" origin.Protocols.Schematics.source
                ^ "/"
                ^ origin.Protocols.Schematics.attribute ) ) )
  | _ -> fail "a derived relation describes itself as a relation"

let releasing_a_derivation_releases_its_inputs () =
  let released = ref false in
  let input =
    object
      method reference = true
      method release = released := true
      method hash = Concepts.Hash.hash_of_int 0
      method protocols : Protocols.Handle.protocol list = []
    end
  in
  let edge = Protocols.Handle.make input in
  let derived =
    Derived.derive ~edges:[edge] (plan_over Concepts.Cardinality.Finite)
    |> Helpers.condition_as_failure
  in
  check bool "an input is held while the derivation lives" false !released;
  Protocols.Handle.release derived;
  check bool "and released with it" true !released

let suites () =
  [ ( "kernel/ephemeral-relation",
      [ test_case "identity-is-the-derivation" `Quick identity_is_the_derivation;
        test_case "an-exhaustible-derivation-enumerates" `Quick an_exhaustible_derivation_enumerates;
        test_case "a-countable-derivation-decides-only" `Quick a_countable_derivation_decides_only;
        test_case "a-derivation-describes-itself" `Quick a_derivation_describes_itself;
        test_case "releasing-a-derivation-releases-its-inputs" `Quick
          releasing_a_derivation_releases_its_inputs ] ) ]
