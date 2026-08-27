module Multigroup = Merkle.StringKey (* FIXME *)

module Make (S : Abstract.Storage.STORAGE) = struct
  (* Branch has a name, a set of multigroups, and a backlink to the previous state
     multigroup has a name and a set of schemas
     schema has a name and a set of relations

     /branch/master/multigroup/universe/schema/sky/relation/planet
   *)

  module SI = Storage.Make (S)

  module MultigroupM = Merkle.Interface (S) (Merkle.StringKey) (Multigroup)

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

  class branch = object
    (* TODO *)
  end

  let load _tx _conn _name _addr = failwith "TODO"
end
