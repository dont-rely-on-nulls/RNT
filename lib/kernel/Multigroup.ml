module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)
  module Sc = Schema.Make (S)
  module SchemaM = Merkle.Interface (S) (Merkle.StringKey) (Sc)
  module SMAddressable = Prototype.Addressable.OfTree (S) (Merkle.StringKey)
  module SMDirectory = Prototype.Directory.OfTree (S) (Merkle.StringKey) (Sc)
  module SMAssociative = Prototype.Associative.OfTree (S) (Merkle.StringKey)

  type t = {schemas: SchemaM.address}

  module Error = struct
    open Concepts.Condition

    let malformed_multigroup () =
      condition "malformed-multigroup"
        "The on-disk representation of a multigroup did not conform to what was expected. Is your \
         database corrupted?"
        empty

    let incomplete_multigroup addr =
      condition "incomplete-multigroup"
        "A stored multigroup is missing part of its expected structure. Is your storage corrupted?"
        ("address" |=| Concepts.Value.String (Concepts.Hash.to_hum_string addr))
  end

  module rec Representation : (Concepts.Encoding.Record.S with type t = t) =
    Concepts.Encoding.Record.Make (Body)

  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let tag = '*'
    let malformed = Error.malformed_multigroup

    let fields {schemas} =
      let open Concepts.Encoding in
      ["schemas", Value.bencode_of_hash schemas]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* schemas = Bencode.field "schemas" fields |> fmap Value.hash_of_bencode in
      Ok {schemas}
  end

  let encode = Representation.to_blob
  let decode = Representation.of_blob

  let node_of tx multigroup =
    let open Utilities.Result in
    SchemaM.find tx multigroup.schemas
    |> fmap (Option.to_result ~none:(Error.incomplete_multigroup multigroup.schemas))

  class multigroup ?bind conn value node =
    object (self)
      inherit Lifecycle.null
      method to_string = "multigroup"
      val multigroup = value
      val storage = conn
      val node = node (* FIXME: see the comment on Branch.ml *)

      (* TODO: Add later to the lifecycle management, accounting for
         derived instances. Callers must release the previous handle
         when done with it so its instance can be cleaned up after the
         last reference is released. *)
      method deriving multigroup' =
        let open Utilities.Result in
        let* node' =
          SI.with_transaction storage (fun tx ->
              let* _ = SI.store_blob tx (Representation.to_blob multigroup') in
              node_of tx multigroup' )
        in
        new multigroup ?bind storage multigroup' node' |> Protocols.Handle.make |> Result.ok

      method protocols : Protocols.Handle.protocol list =
        let open Utilities.Result in
        Protocols.
          [ Addressable.make self;
            Prototype.Associative.(
              of_properties
                [ ( "schema",
                    update_only (fun node' ->
                        Handle.require Addressable.from node'
                        |> Result.map Addressable.address
                        |> fmap (fun addr -> self#deriving {schemas= addr}) ) ) ] );
            Prototype.Directory.of_properties
              [ ( "schema",
                  Prototype.mixture_of node (fun make node ->
                      [ SMAddressable.make ~node:(SchemaM.into node);
                        SMDirectory.make ~storage ~node ~constructor:(Sc.load ?bind storage);
                        SMAssociative.make ~admit:Sc.admit ~storage ~node:(SchemaM.into node)
                          ~constructor:(fun node' -> SchemaM.from node' |> make |> Result.ok)
                          () ] ) ) ] ]

      method hash = Representation.to_blob multigroup |> Concepts.Hash.hash_of_blob
      method address = self#hash
    end

  let load ?bind conn value =
    let open Utilities.Result in
    let* node = SI.with_read conn (fun tx -> node_of tx value) in
    new multigroup ?bind conn value node |> Protocols.Handle.make |> Result.ok

  let make conn =
    let open Utilities.Result in
    SI.with_transaction conn (fun tx ->
        let* empty = SchemaM.empty_under tx in
        let multigroup = {schemas= empty} in
        let* _ = SI.store_blob tx (Representation.to_blob multigroup) in
        new multigroup conn multigroup SchemaM.empty |> Protocols.Handle.make |> Result.ok )

  (* Handed over as the tree shows one, a directory holding its schemas
     under \schema, a multigroup not stored yet is stored with them. *)
  let admit _ h =
    let open Utilities.Result in
    let* listing = Protocols.Handle.require Protocols.Directory.from h in
    let* schemas = Protocols.Directory.find listing "schema" in
    let* schemas =
      match schemas with
      | None -> Ok []
      | Some schemas ->
          let* listing = Protocols.Handle.require Protocols.Directory.from schemas in
          let* names = Protocols.Directory.list listing in
          BatFingerTree.to_list names
          |> List.filter_map (fun name ->
              match Protocols.Directory.find listing name with
              | Ok None -> None
              | Error c -> Some (Error c)
              | Ok (Some schema) -> (
                match Protocols.Addressable.from schema with
                | Some a ->
                    let addr = Protocols.Addressable.address a in
                    Some (Ok (name, fun _ -> Ok addr))
                | None -> Some (Sc.admit name schema |> Result.map (fun p -> name, p)) ) )
          |> Utilities.List.sequence
    in
    Ok
      (fun tx ->
        let* _ = SchemaM.empty_under tx in
        let* node =
          SchemaM.with_batch tx (fun () ->
              List.fold_left
                (fun node (name, store) ->
                  let* node = node in
                  let* addr = store tx in
                  SchemaM.Tree.insert tx name addr (SchemaM.into node) |> Result.map SchemaM.from )
                (Ok SchemaM.empty) schemas )
        in
        SI.store_blob tx (Representation.to_blob {schemas= SchemaM.hash_of node}) )
end
