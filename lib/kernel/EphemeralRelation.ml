type program = {evaluator: string; code: Concepts.Hash.hash}

type t =
  { name: string option;
    schematics:
      [ `Persisted of Concepts.Hash.hash
      | `Temporary of Protocols.Schematics.attribute_description BatMap.String.t ];
    program: program option }

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

class ephemeral_relation ?program description value enumerate inputs =
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
      let protocols =
        Protocols.[Relation.make self; Enumerable.make self; Schematics.make self]
        @ Option.fold ~none:[] ~some:Protocols.Handle.protocols program
      in
      match persisted relation with
      | None -> protocols
      | Some record ->
          Protocols.Addressable.make
            object
              method address = Persisted.Representation.to_blob record |> Concepts.Hash.hash_of_blob
            end
          :: protocols
  end

let instantiate ?(inputs = []) ?program description value enumerate =
  new ephemeral_relation ?program description value enumerate inputs |> Protocols.Handle.make

let literal description tuples =
  instantiate description
    {name= None; schematics= `Temporary description; program= None}
    (fun () -> Ok (Generator.cursor_of (fun ~yield -> List.iter yield tuples; Ok ())))

type binding = {root: Protocols.Handle.t; within: Protocols.Handle.t}

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

let run name program within () =
  let open Utilities.Result in
  match program, within with
  | Some program, Some within ->
      let* executable = Protocols.Executable.require program in
      Result.bind (Protocols.Executable.invoke executable [] ~within) enumerate_owned
  | _ -> Error (Error.unbound_program name)

let view ?within description program =
  instantiate ~program description
    {name= None; schematics= `Temporary description; program= None}
    (run (Protocols.Handle.to_string program) (Some program) within)

module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)
  module R = SubstantialRelation.Make (S)

  let restore ?program ?within ({Persisted.name; schematics; program= pointer} : Persisted.t)
      description =
    instantiate ?program description
      {name= Some name; schematics= `Persisted schematics; program= Some pointer}
      (run name program within)

  let load ?bind connection (record : Persisted.t) =
    let open Utilities.Result in
    let* description, source =
      SI.with_read connection (fun tx ->
          let* description = R.schema_of tx record.schematics in
          let* code = SI.get_req tx (S.Hash record.program.code) in
          Ok (description, Bytes.to_string (Concepts.Blob.bytes_of_blob code)) )
    in
    match bind with
    | None -> Ok (restore record description)
    | Some {root; within} ->
        let* program = Program.load root ~evaluator:record.program.evaluator ~source in
        Ok (restore ~program ~within record description)

  let store tx ~name ~evaluator ~source description =
    let open Utilities.Result in
    let* schematics = R.store_schema tx description in
    let* address = SI.store_blob tx (Concepts.Blob.blob_of_bytes (Bytes.of_string source)) in
    let record = {Persisted.name; schematics; program= {evaluator; code= address}} in
    let* _ = SI.store_blob tx (Persisted.Representation.to_blob record) in
    Ok record

  let persist connection ~name program description =
    let open Utilities.Result in
    let* {Program.evaluator; source; _} = Program.require program in
    SI.with_transaction connection (fun tx ->
        let* record = store tx ~name ~evaluator ~source description in
        Ok (restore ~program record description) )
end
