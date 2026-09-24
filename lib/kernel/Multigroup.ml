module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)

  module R = SubstantialRelation.Make (S)
  module RelationM = Merkle.Interface (S) (Merkle.StringKey) (R)
  module RMDirectory = Prototype.Directory.OfTree (S) (Merkle.StringKey) (R)

  type t = { relations : RelationM.address }

  module Error = struct
    open Concepts.Condition

    let malformed_multigroup () = condition "malformed-multigroup" "The on-disk representation of a multigroup did not conform to what was expected. Is your database corrupted?"
                                    empty

    let incomplete_multigroup addr = condition "incomplete-multigroup" "A stored multigroup is missing part of its expected structure. Is your storage corrupted?"
                                       ("address" |=| Concepts.Value.String (Concepts.Hash.to_hum_string addr))
  end

  module rec Representation : Concepts.Encoding.Record.S with type t = t = Concepts.Encoding.Record.Make (Body)
  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let tag = '*'
    let malformed = Error.malformed_multigroup

    let fields { relations } =
      let open Concepts.Encoding in
      ["relations", Value.bencode_of_hash relations]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* relations = Bencode.field "relations" fields |> fmap Value.hash_of_bencode in
      Ok { relations }
  end

  let encode = Representation.to_blob
  let decode = Representation.of_blob

  class multigroup conn value node = object (self)
    inherit Lifecycle.null

    method to_string = "multigroup"

    val multigroup = value
    val storage = conn
    val node = node (* FIXME: see the comment on Branch.ml *)

    method protocols : Protocols.Handle.protocol list =
      Protocols.[ Addressable.make self;
                  Prototype.Directory.of_properties
                    [ "relation", Prototype.mixture
                                    [ RMDirectory.make
                                        ~storage ~node
                                        ~constructor:(R.wrap storage) ] ] ]

    method hash =
      Representation.to_blob multigroup
      |> Concepts.Hash.hash_of_blob

    method address = self#hash
  end

  let wrap conn value =
    let open Utilities.Result in
    let* node = SI.with_transaction conn (fun tx -> RelationM.find tx value.relations)
                |> fmap (Option.to_result ~none:(Error.incomplete_multigroup value.relations)) in
    new multigroup conn value node |> Protocols.Handle.make |> Result.ok

  let make conn =
    let open Utilities.Result in
    SI.with_transaction conn (fun tx ->
        let* empty = RelationM.empty_under tx in
        let multigroup = { relations = empty } in
        let* _ = SI.store_blob tx (Representation.to_blob multigroup) in
        new multigroup conn multigroup RelationM.empty |> Protocols.Handle.make |> Result.ok)
end
