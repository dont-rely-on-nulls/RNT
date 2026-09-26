type t =
  { schematics:
      [ `Persisted of Concepts.Hash.hash
      | `Temporary of Protocols.Schematics.attribute_description BatMap.String.t ] }

module Error = struct
  (* open Concepts.Condition *)
end

class ephemeral_relation description value enumerate inputs =
  object (self)
    inherit Lifecycle.counted
    inherit Identity.of_id
    method to_string = "ephemeral-relation"
    val relation : t = value
    method destroy = List.iter Protocols.Handle.release inputs
    method enumerate : (Protocols.Handle.t, Concepts.Condition.condition) result = enumerate ()
    method describe () = Ok (Protocols.Schematics.Relation description)

    method contains (tuple : Concepts.Tuple.t) =
      let open Utilities.Result in
      let* cursor = self#enumerate in
      Fun.protect
        ~finally:(fun () -> Protocols.Handle.release cursor)
        (fun () ->
          let* scan = Protocols.Cursor.require cursor in
          Protocols.Cursor.exists scan (fun member ->
              Concepts.Hash.hash_equals (Concepts.Tuple.hash member) (Concepts.Tuple.hash tuple) ) )

    method protocols : Protocols.Handle.protocol list =
      Protocols.[Relation.make self; Enumerable.make self; Schematics.make self]
  end

let instantiate ?(inputs = []) description value enumerate =
  new ephemeral_relation description value enumerate inputs |> Protocols.Handle.make
