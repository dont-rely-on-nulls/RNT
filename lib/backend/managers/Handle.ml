module type HANDLER = sig
  type t
  type handle
  type cursor

  val open_ :
    t ->
    Permission.capability ->
    path:Permission.path ->
    claim:Permission.claim ->
    (handle, Concepts.Condition.condition) result

  val open_cursor :
    handle ->
    args:Concepts.Value.value BatFingerTree.t ->
    (cursor, Concepts.Condition.condition) result

  val next : cursor -> (Concepts.Tuple.t option, Concepts.Condition.condition) result
  val close : cursor -> unit
end

let blocked (path : Permission.path) (claim : Permission.claim) : Concepts.Condition.condition =
  let open Concepts.Condition in
  let path_string = Concepts.Path.to_string path in
  condition "access-blocked"
    (Printf.sprintf "capability does not authorize %s on %S" (Permission.claim_name claim)
       path_string )
    ("path" |=| Concepts.Value.String path_string)

let not_a_relation () : Concepts.Condition.condition =
  Concepts.Condition.condition "not-a-relation"
    "handle does not refer to a stored or ephemeral relation" Concepts.Condition.empty

module Make (Store : Abstract.Storage.STORAGE) = struct
  module Cur = Cursor.Make (Store)

  type t = {objects: Object.rnt_object_tree; txn: Store.transaction}
  type handle = {object_: Object.registry; capability: Permission.capability; txn: Store.transaction}
  type cursor = Cur.cursor

  let create objects txn = {objects; txn}

  let open_ t cap ~path ~claim =
    if not (Permission.authorizes cap path claim) then Error (blocked path claim)
    else
      match Permission.attenuate cap ~scope:path () with
      | None -> Error (blocked path claim)
      | Some capability ->
          let object_ = Object.find path t.objects in
          Ok {object_; capability; txn= t.txn}

  let relation_descriptor (object_ : Object.registry) :
      (Cursor.descriptor, Concepts.Condition.condition) result =
    let {Object.entry; _} = object_ in
    match entry.Object.kind with
    | Object.Relation {merkle_root} -> Ok (Cursor.Stored {merkle_root})
    | Object.EphemeralRelation {merkle_root; dependencies} ->
        Ok (Cursor.Ephemeral {merkle_root; dependencies})
    | _ -> Error (not_a_relation ())

  let open_cursor handle ~args =
    let open Utilities.Result in
    let* descriptor = relation_descriptor handle.object_ in
    Cur.open_ handle.txn descriptor ~args

  let next = Cur.next
  let close = Cur.close
  let object_ (handle : handle) = handle.object_
  let capability (handle : handle) = handle.capability
end
