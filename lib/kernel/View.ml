type heading = Protocols.Schematics.attribute_description BatMap.String.t
type rows = (Concepts.Tuple.t list, Concepts.Condition.condition) result

let ephemeral heading enumerate =
  EphemeralRelation.instantiate heading
    {EphemeralRelation.name= None; schematics= `Temporary heading; program= None}
    (fun () ->
      Result.map
        (fun tuples -> Generator.cursor_of (fun ~yield -> List.iter yield tuples; Ok ()))
        (enumerate ()) )

let fixed heading tuples = ephemeral heading (fun () -> Ok tuples)

let computed heading ~current compute =
  let open Utilities.Result in
  let now = ephemeral heading (fun () -> current () |> fmap compute) in
  Prototype.mixture
    ( Protocols.Derived.make
        object
          method within directory = Ok (ephemeral heading (fun () -> compute directory))
        end
    :: Protocols.Handle.protocols now )

let read relation =
  let open Utilities.Result in
  let* schematics = Protocols.Handle.require Protocols.Schematics.from relation in
  let* description = Protocols.Schematics.describe schematics in
  let* heading =
    match description with
    | Protocols.Schematics.Relation heading -> Ok heading
    | _ ->
        Error
          Concepts.Condition.(
            condition "not-a-relation" "The object does not describe itself as a relation"
              ("object" |=| Concepts.Value.String (Protocols.Handle.to_string relation)) )
  in
  let* enumerable = Protocols.Enumerable.require relation in
  let* cursor = Protocols.Enumerable.enumerate enumerable in
  Fun.protect
    ~finally:(fun () -> Protocols.Handle.release cursor)
    (fun () ->
      let* scan = Protocols.Cursor.require cursor in
      let* tuples = Protocols.Cursor.drain scan () in
      Ok (heading, BatFingerTree.to_list tuples) )
