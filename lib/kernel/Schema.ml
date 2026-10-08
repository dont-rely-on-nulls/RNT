module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)
  module R = SubstantialRelation.Make (S)
  module E = EphemeralRelation.Make (S)

  (* A relation as a schema holds it. *)
  module Entry = struct
    module Stored = EphemeralRelation.Persisted.Representation

    type t = Substantial of R.t | Ephemeral of EphemeralRelation.Persisted.t

    let encode = function
      | Substantial relation -> R.encode relation
      | Ephemeral relation -> Stored.to_blob relation

    let decode blob =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* data = Bencode.of_blob blob in
      match data with
      | Bencode.Tagged (tag, _) when Char.equal tag Stored.tag ->
          Stored.of_bencode data |> Result.map (fun relation -> Ephemeral relation)
      | _ -> R.Representation.of_bencode data |> Result.map (fun relation -> Substantial relation)

    let load ?bind storage = function
      | Substantial relation -> R.load storage relation
      | Ephemeral relation -> E.load ?bind storage relation

    (* A program is stored as itself, to run whenever it is read; any
       other relation is stored as the tuples it holds now. *)
    let admit name h =
      let open Utilities.Result in
      let address entry = Concepts.Hash.hash_of_blob (encode entry) in
      match EphemeralRelation.stored h with
      | Some (evaluator, code, _) ->
          let* description = Protocols.Relation.heading h in
          Ok
            (fun tx ->
              let* record = E.store tx ~name ~evaluator ~code description in
              Ok (address (Ephemeral record)) )
      | None ->
          let* description, tuples = Protocols.Relation.read h in
          Ok
            (fun tx ->
              let* relation = R.store tx description tuples in
              Ok (address (Substantial relation)) )
  end

  module RelationM = Merkle.Interface (S) (Merkle.StringKey) (Entry)
  module RMAddressable = Prototype.Addressable.OfTree (S) (Merkle.StringKey)
  module RMDirectory = Prototype.Directory.OfTree (S) (Merkle.StringKey) (Entry)
  module RMAssociative = Prototype.Associative.OfTree (S) (Merkle.StringKey)

  type t = {relations: RelationM.address}

  module Error = struct
    open Concepts.Condition

    let malformed_schema () =
      condition "malformed-schema"
        "The on-disk representation of a schema did not conform to what was expected. Is your \
         database corrupted?"
        empty

    let incomplete_schema addr =
      condition "incomplete-schema"
        "A stored schema is missing part of its expected structure. Is your storage corrupted?"
        ("address" |=| Concepts.Value.String (Concepts.Hash.to_hum_string addr))
  end

  module rec Representation : (Concepts.Encoding.Record.S with type t = t) =
    Concepts.Encoding.Record.Make (Body)

  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let tag = 'S'
    let malformed = Error.malformed_schema

    let fields {relations} =
      let open Concepts.Encoding in
      ["relations", Value.bencode_of_hash relations]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* relations = Bencode.field "relations" fields |> fmap Value.hash_of_bencode in
      Ok {relations}
  end

  let encode = Representation.to_blob
  let decode = Representation.of_blob

  let node_of tx schema =
    let open Utilities.Result in
    RelationM.find tx schema.relations
    |> fmap (Option.to_result ~none:(Error.incomplete_schema schema.relations))

  class schema ?bind conn value node =
    object (self)
      inherit Lifecycle.null
      method to_string = "schema"
      val schema = value
      val storage = conn
      val node = node (* FIXME: see the comment on Branch.ml *)

      (* TODO: Add later to the lifecycle management, accounting for
         derived instances. Callers must release the previous handle
         when done with it so its instance can be cleaned up after the
         last reference is released. *)
      method deriving schema' =
        let open Utilities.Result in
        let* node' =
          SI.with_transaction storage (fun tx ->
              let* _ = SI.store_blob tx (Representation.to_blob schema') in
              node_of tx schema' )
        in
        new schema ?bind storage schema' node' |> Protocols.Handle.make |> Result.ok

      method protocols : Protocols.Handle.protocol list =
        let open Utilities.Result in
        Protocols.
          [ Addressable.make self;
            Prototype.Associative.(
              of_properties
                [ ( "relation",
                    update_only (fun node' ->
                        Handle.require Addressable.from node'
                        |> Result.map Addressable.address
                        |> fmap (fun addr -> self#deriving {relations= addr}) ) ) ] );
            Prototype.Directory.of_properties
              [ ( "relation",
                  Prototype.mixture_of node (fun make node ->
                      [ RMAddressable.make ~node:(RelationM.into node);
                        RMDirectory.make ~storage ~node ~constructor:(Entry.load ?bind storage);
                        RMAssociative.make ~admit:Entry.admit ~storage ~node:(RelationM.into node)
                          ~constructor:(fun node' -> RelationM.from node' |> make |> Result.ok)
                          () ] ) ) ] ]

      method hash = Representation.to_blob schema |> Concepts.Hash.hash_of_blob
      method address = self#hash
    end

  let load ?bind conn value =
    let open Utilities.Result in
    let* node = SI.with_read conn (fun tx -> node_of tx value) in
    new schema ?bind conn value node |> Protocols.Handle.make |> Result.ok

  let make conn =
    let open Utilities.Result in
    SI.with_transaction conn (fun tx ->
        let* empty = RelationM.empty_under tx in
        let schema = {relations= empty} in
        let* _ = SI.store_blob tx (Representation.to_blob schema) in
        new schema conn schema RelationM.empty |> Protocols.Handle.make |> Result.ok )

  (* Handed over as the tree shows one, a directory holding its relations
     under \relation, a schema not stored yet is stored with them. *)
  let admit _ h =
    let open Utilities.Result in
    let* listing = Protocols.Handle.require Protocols.Directory.from h in
    let* relations = Protocols.Directory.find listing "relation" in
    let* relations =
      match relations with
      | None -> Ok []
      | Some relations ->
          let* listing = Protocols.Handle.require Protocols.Directory.from relations in
          let* names = Protocols.Directory.list listing in
          BatFingerTree.to_list names
          |> List.filter_map (fun name ->
              match Protocols.Directory.find listing name with
              | Ok None -> None
              | Error c -> Some (Error c)
              | Ok (Some relation) -> (
                match Protocols.Addressable.from relation with
                | Some a ->
                    let addr = Protocols.Addressable.address a in
                    Some (Ok (name, fun _ -> Ok addr))
                | None -> Some (Entry.admit name relation |> Result.map (fun p -> name, p)) ) )
          |> Utilities.List.sequence
    in
    Ok
      (fun tx ->
        let* _ = RelationM.empty_under tx in
        let* node =
          RelationM.with_batch tx (fun () ->
              List.fold_left
                (fun node (name, store) ->
                  let* node = node in
                  let* addr = store tx in
                  RelationM.Tree.insert tx name addr (RelationM.into node)
                  |> Result.map RelationM.from )
                (Ok RelationM.empty) relations )
        in
        SI.store_blob tx (Representation.to_blob {relations= RelationM.hash_of node}) )
end
