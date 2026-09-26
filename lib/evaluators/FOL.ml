module Error = struct
  open Concepts.Condition

  let unknown_relation name =
    condition "unknown-relation" "A plan named a relation that does not exist under this snapshot"
      ("name" |=| Concepts.Value.String name)

  let cancelled () =
    condition "evaluation-cancelled" "An evaluation was stopped before it produced its result" empty

  let not_a_plan name =
    condition "not-a-fol-program" "The evaluator was given an object that carries no FOL plan"
      ("object" |=| Concepts.Value.String name)

  let not_a_relation name =
    condition "not-a-relation" "A plan named an object that does not describe itself as a relation"
      ("object" |=| Concepts.Value.String name)

  let unknown_attribute name =
    condition "unknown-attribute" "A plan projected an attribute its relation does not have"
      ("attribute" |=| Concepts.Value.String name)

  let released_relation name =
    condition "released-relation" "A plan named a relation that was already released"
      ("object" |=| Concepts.Value.String name)
end

type plan = Base of Protocols.Handle.t | Project of plan * string BatFingerTree.t
type Protocols.Handle.protocol += Plan of plan

class program plan =
  object
    inherit Kernel.Lifecycle.null
    inherit Kernel.Identity.of_id
    method to_string = "fol-program"
    method protocols : Protocols.Handle.protocol list = [Plan plan]
  end

let program plan = new program plan |> Protocols.Handle.make

let restrict attributes description =
  let open Utilities.Result in
  BatFingerTree.fold_left
    (fun restricted name ->
      let* restricted = restricted in
      let* attribute =
        BatMap.String.find_opt name description
        |> Option.to_result ~none:(Error.unknown_attribute name)
      in
      Ok (BatMap.String.add name attribute restricted) )
    (Ok BatMap.String.empty) attributes

let rec describe =
  let open Utilities.Result in
  function
  | Base relation -> (
      let* schematics = Protocols.Handle.require Protocols.Schematics.from relation in
      let* description = Protocols.Schematics.describe schematics in
      match description with
      | Protocols.Schematics.Relation description -> Ok description
      | _ -> Error (Error.not_a_relation (Protocols.Handle.to_string relation)) )
  | Project (plan, attributes) -> describe plan |> fmap (restrict attributes)

let enumerate relation =
  let open Utilities.Result in
  let* enumerable = Protocols.Enumerable.require relation in
  Protocols.Enumerable.enumerate enumerable

let project description relation =
  let open Utilities.Result in
  let* cursor = enumerate relation in
  let produce ~yield =
    let* scan = Protocols.Cursor.require cursor in
    let rec distinct seen =
      let* next = Protocols.Cursor.next scan in
      match next with
      | None -> Ok ()
      | Some tuple ->
          let tuple =
            { tuple with
              attributes=
                BatMap.String.filter
                  (fun name _ -> BatMap.String.mem name description)
                  tuple.Concepts.Tuple.attributes }
          in
          let key = Concepts.Tuple.hash tuple |> Concepts.Hash.to_raw_string in
          if BatSet.String.mem key seen then distinct seen
          else begin
            yield tuple;
            distinct (BatSet.String.add key seen)
          end
    in
    distinct BatSet.String.empty
  in
  Ok (Kernel.Generator.cursor_of ~finally:(fun () -> Protocols.Handle.release cursor) produce)

let derive relation description enumerate =
  Kernel.EphemeralRelation.instantiate ~inputs:[relation] description
    {Kernel.EphemeralRelation.schematics= `Temporary description}
    (fun () -> enumerate relation)

let rec execute plan =
  let open Utilities.Result in
  let* description = describe plan in
  match plan with
  | Base relation ->
      let* relation =
        Protocols.Handle.copy relation
        |> Option.to_result ~none:(Error.released_relation (Protocols.Handle.to_string relation))
      in
      Ok (derive relation description enumerate)
  | Project (plan, _) ->
      let* relation = execute plan in
      Ok (derive relation description (project description))

class evaluator =
  object (self)
    inherit Kernel.Lifecycle.null
    inherit Kernel.Identity.of_id
    method to_string = "fol-evaluator"

    method invoke program =
      Protocols.Handle.into program (function Plan plan -> Some plan | _ -> None)
      |> Option.to_result ~none:(Error.not_a_plan (Protocols.Handle.to_string program))
      |> Utilities.Result.fmap (fun plan -> Protocols.Handle.invoke plan execute)

    method protocols : Protocols.Handle.protocol list = [Protocols.Evaluator.make self]
  end

let make () = new evaluator |> Protocols.Handle.make
