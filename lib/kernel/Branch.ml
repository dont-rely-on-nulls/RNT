module Multigroup = Merkle.StringKey (* FIXME *)

module Make (S : Abstract.Storage.STORAGE) = struct
  (* Branch has a name, a set of multigroups, and a backlink to the previous state
     multigroup has a name and a set of schemas
     schema has a name and a set of relations

     /branch/master/multigroup/universe/schema/sky/relation/planet
   *)

  module SI = Storage.Make (S)

  module MultigroupM = Merkle.Interface (S) (Merkle.StringKey) (Multigroup)
  module MMDirectory = Prototype.Directory.OfTree (S) (Merkle.StringKey) (Multigroup)

  module Error = struct
    open Concepts.Condition

    let incomplete_branch addr = condition "incomplete-branch" "A stored branch is missing part of it's expected structure. Is your storage corrupted?"
                                   ("address" |=| Concepts.Value.String (Concepts.Hash.to_hum_string addr))
  end

  type t = {
    multigroups : MultigroupM.address;
    previous : t SI.Pointer.t option
  }

  module rec Representation : Concepts.Encoding.Record.S with type t = t = Concepts.Encoding.Record.Make (Body)
  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let load tx addr =
      SI.get_req tx addr
      |> Utilities.Result.fmap Representation.of_blob

    let tag = 'Y'
    let malformed () =
      Concepts.Condition.
      (condition "malformed-branch" "The on-disk representation of a branch did not conform to what was expected. Is your database corrupted?"
         empty)

    let fields { multigroups; previous } =
      let open Concepts.Encoding in
      ["multigroups", Value.bencode_of_hash multigroups;
       "previous", Value.bencode_of_option
                     (fun v -> SI.Pointer.address_of v
                               |> SI.as_hash
                               |> Value.bencode_of_hash)
                     previous]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* multigroups = Bencode.field "multigroups" fields |> fmap Value.hash_of_bencode in
      let* previous = Bencode.field "previous" fields
                      |> fmap (Value.option_of_bencode
                                 (fun v -> Value.hash_of_bencode v
                                           |> Result.map (fun hash -> S.Hash hash)
                                           |> Result.map (Fun.flip (SI.Pointer.make) load))) in
      Ok { multigroups; previous }
  end

  class branch storage value node = object
    inherit Lifecycle.null

    val storage : S.connection = storage
    val branch : t = value
    val node : MultigroupM.node = node (* FIXME: can we not place this inside `t`? *)

    method protocols : Protocols.Handle.protocol list =
      [ Prototype.Directory.of_properties
          [ "multigroups", Prototype.mixture
                            [ MMDirectory.make
                                ~storage ~node
                                ~constructor:(fun _e -> failwith "TODO") ] ] ]

    method hash =
      Representation.to_blob branch
      |> Concepts.Hash.hash_of_blob
  end

  let load tx conn addr =
    let open Utilities.Result in
    let* data = SI.get_req tx (S.Hash addr) in
    let* branch = Representation.of_blob data in
    let* node = MultigroupM.find tx branch.multigroups |> fmap (Option.to_result ~none:(Error.incomplete_branch addr)) in
    Ok (new branch conn branch node |> Protocols.Handle.make)

  let make conn =
    let open Utilities.Result in
    SI.with_transaction conn (fun tx ->
        let* empty = MultigroupM.empty_under tx in
        let branch = { multigroups = empty; previous = None } in
        let* _ = SI.store_blob tx (Representation.to_blob branch) in
        Ok (new branch conn branch MultigroupM.empty |> Protocols.Handle.make))
end
