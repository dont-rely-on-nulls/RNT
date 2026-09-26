open Alcotest
module Concepts = Rnt.Concepts
module Protocols = Rnt.Protocols
module Ephemeral = Rnt.Kernel.EphemeralRelation

let member n =
  { Concepts.Tuple.type_= "example";
    attributes= BatMap.String.singleton "value" (Concepts.Value.Integer n) }

let description =
  BatMap.String.singleton "value"
    { Protocols.Schematics.domain= "integer";
      provenance= [{Protocols.Schematics.source= ["example"]; attribute= "value"}] }

let over ?inputs members =
  Ephemeral.instantiate ?inputs description
    {Ephemeral.schematics= `Temporary description}
    (fun () -> Ok (Rnt.Kernel.Generator.cursor_of (fun ~yield -> List.iter yield members; Ok ())))

let values tuples =
  BatFingerTree.to_list tuples
  |> List.filter_map (fun tuple ->
      match BatMap.String.find_opt "value" tuple.Concepts.Tuple.attributes with
      | Some (Concepts.Value.Integer n) -> Some n
      | _ -> None )
  |> List.sort compare

let enumerates_every_member () =
  let enumerated =
    begin
      let open Rnt.Utilities.Result in
      let* enumerable = Protocols.Enumerable.require (over [member 1; member 2; member 3]) in
      let* cursor = Protocols.Enumerable.enumerate enumerable in
      let* scan = Protocols.Cursor.require cursor in
      let* tuples = Protocols.Cursor.drain scan () in
      Protocols.Handle.release cursor;
      Ok (values tuples)
    end
    |> Helpers.condition_as_failure
  in
  check (list int) "every member" [1; 2; 3] enumerated

let decides_membership () =
  let holds, rejects =
    begin
      let open Rnt.Utilities.Result in
      let* relation = Protocols.Relation.require (over [member 1; member 2; member 3]) in
      let* holds = Protocols.Relation.contains relation (member 2) in
      let* rejects = Protocols.Relation.contains relation (member 9) in
      Ok (holds, rejects)
    end
    |> Helpers.condition_as_failure
  in
  check bool "a member is held" true holds;
  check bool "a stranger is refused" false rejects

let describes_itself () =
  let described =
    begin
      let open Rnt.Utilities.Result in
      let* schematics = Protocols.Handle.require Protocols.Schematics.from (over []) in
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
  | _ -> fail "an ephemeral relation describes itself as a relation"

let releasing_releases_its_inputs () =
  let released = ref false in
  let input =
    object
      method reference = true
      method release = released := true
      method hash = Concepts.Hash.hash_of_int 0
      method to_string = "input"
      method protocols : Protocols.Handle.protocol list = []
    end
  in
  let relation = over ~inputs:[Protocols.Handle.make input] [] in
  check bool "an input is held while the relation lives" false !released;
  Protocols.Handle.release relation;
  check bool "and released with it" true !released

let suites () =
  [ ( "kernel/ephemeral-relation",
      [ test_case "enumerates-every-member" `Quick enumerates_every_member;
        test_case "decides-membership" `Quick decides_membership;
        test_case "describes-itself" `Quick describes_itself;
        test_case "releasing-releases-its-inputs" `Quick releasing_releases_its_inputs ] ) ]
