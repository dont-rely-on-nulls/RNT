type program = {evaluator: string; code: Concepts.Hash.hash}

type t =
  { name: string option;
    schematics:
      [ `Persisted of Concepts.Hash.hash
      | `Temporary of Protocols.Schematics.attribute_description BatMap.String.t ];
    program: program option }

(* [name] is the relation a stored program defines, once it is read from
   where it was stored under that name. *)
type Protocols.Handle.protocol +=
  | Stored of {evaluator: string; code: Concepts.Blob.t; name: string option}

let stored handle =
  Protocols.Handle.into handle (function
    | Stored {evaluator; code; name} -> Some (evaluator, code, name)
    | _ -> None )
  |> Option.map (fun i -> Protocols.Handle.invoke i Fun.id)

module Error = struct
  open Concepts.Condition

  let malformed_relation () =
    condition "malformed-ephemeral-relation"
      "The on-disk representation of an ephemeral relation did not conform to what was expected. \
       Is your database corrupted?"
      empty

  let unbound_program name =
    condition "unbound-program"
      "A stored relation has to be instantiated by its evaluator before it can be enumerated"
      ("relation" |=| Concepts.Value.String name)
end

module Persisted = struct
  type nonrec t = {name: string; schematics: Concepts.Hash.hash; program: program}

  module rec Representation : (Concepts.Encoding.Record.S with type t = t) =
    Concepts.Encoding.Record.Make (Body)

  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let tag = 'E'
    let malformed = Error.malformed_relation

    let fields {name; schematics; program= {evaluator; code}} =
      let open Concepts.Encoding in
      [ "name", Field.string name;
        "schema", Value.bencode_of_hash schematics;
        "evaluator", Field.string evaluator;
        "program", Value.bencode_of_hash code ]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* name = Field.require_string "name" fields in
      let* schematics = Bencode.field "schema" fields |> fmap Value.hash_of_bencode in
      let* evaluator = Field.require_string "evaluator" fields in
      let* code = Bencode.field "program" fields |> fmap Value.hash_of_bencode in
      Ok {name; schematics; program= {evaluator; code}}
  end
end

(* FIXME: Bring the Persisted/Temporary out to avoid using the
   wildcard and optionals *)
let persisted = function
  | {name= Some name; schematics= `Persisted schematics; program= Some program} ->
      Some {Persisted.name; schematics; program}
  | _ -> None

class ephemeral_relation ?code description value enumerate inputs =
  object (self)
    inherit Lifecycle.counted
    inherit Identity.of_id
    method to_string = "ephemeral-relation"
    val relation : t = value
    method destroy = List.iter Protocols.Handle.release inputs
    method enumerate : (Protocols.Handle.t, Concepts.Condition.condition) result = enumerate ()
    method describe () = Ok (Protocols.Schematics.Relation description)

    (* TODO: We do not need to scan, but simply apply a membership
       criteria (set of constraints. For now this works, but it's
       inneficient and hurts data independence, as there is an
       assymetry between ephemeral and substantial relations. *)
    method contains (tuple : Concepts.Tuple.t) =
      let open Utilities.Result in
      let* cursor = self#enumerate in
      Protocols.Handle.releasing cursor (fun () ->
          let* scan = Protocols.Cursor.require cursor in
          Protocols.Cursor.exists scan (fun member ->
              Concepts.Hash.hash_equals (Concepts.Tuple.hash member) (Concepts.Tuple.hash tuple) ) )

    method protocols : Protocols.Handle.protocol list =
      let protocols = Protocols.[Relation.make self; Enumerable.make self; Schematics.make self] in
      match persisted relation with
      | None -> protocols
      | Some record ->
          let stored =
            Option.fold ~none:protocols
              ~some:(fun code ->
                Stored {evaluator= record.program.evaluator; code; name= Some record.name}
                :: protocols )
              code
          in
          Protocols.Addressable.make
            object
              method address = Persisted.Representation.to_blob record |> Concepts.Hash.hash_of_blob
            end
          :: stored
  end

let instantiate ?(inputs = []) ?code description value enumerate =
  new ephemeral_relation ?code description value enumerate inputs |> Protocols.Handle.make

let literal description tuples =
  instantiate description
    {name= None; schematics= `Temporary description; program= None}
    (fun () -> Ok (Generator.cursor_of (fun ~yield -> List.iter yield tuples; Ok ())))

type binding =
  string -> Protocols.Handle.t -> (Protocols.Handle.t, Concepts.Condition.condition) result

(* The relation a program produced has to outlive the cursor over it. *)
let enumerate_owned relation =
  let open Utilities.Result in
  let owner =
    object
      method reference = true
      method release = Protocols.Handle.release relation
    end
  in
  match
    let* enumerable = Protocols.Enumerable.require relation in
    Protocols.Enumerable.enumerate enumerable
  with
  | Error c -> Protocols.Handle.release relation; Error c
  | Ok cursor ->
      Ok
        (Protocols.Handle.make
           object
             inherit Lifecycle.retaining cursor owner
             method to_string = Protocols.Handle.to_string cursor
           end )

module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)
  module R = SubstantialRelation.Make (S)

  (* Unbound, a stored program is only its source. Bound, enumerating
     it runs the program through its evaluator, afresh each time. *)
  let restore ?bind ~code ({Persisted.name; schematics; program} : Persisted.t) description =
    let enumerate () =
      match bind with
      | None -> Error (Error.unbound_program name)
      | Some bind ->
          let source =
            Prototype.mixture [Stored {evaluator= program.evaluator; code; name= Some name}]
          in
          Result.bind (bind program.evaluator source) enumerate_owned
    in
    instantiate ~code description
      {name= Some name; schematics= `Persisted schematics; program= Some program}
      enumerate

  let load ?bind connection (record : Persisted.t) =
    SI.with_read connection (fun tx ->
        let open Utilities.Result in
        let* description = R.schema_of tx record.schematics in
        let* code = SI.get_req tx (S.Hash record.program.code) in
        Ok (restore ?bind ~code record description) )

  let store tx ~name ~evaluator ~code description =
    let open Utilities.Result in
    let* schematics = R.store_schema tx description in
    let* address = SI.store_blob tx code in
    let record = {Persisted.name; schematics; program= {evaluator; code= address}} in
    let* _ = SI.store_blob tx (Persisted.Representation.to_blob record) in
    Ok record

  let persist connection ~name ~evaluator ~code description =
    SI.with_transaction connection (fun tx ->
        let open Utilities.Result in
        let* record = store tx ~name ~evaluator ~code description in
        Ok (restore ~code record description) )
end
