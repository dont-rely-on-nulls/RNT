type ordering = Equal | Smaller | Greater

class type ['a] key = object
  method value : 'a
  method encode : Concepts.Representation.blob
  method compare : 'a key -> ordering
end

module type TREE = functor (S : Abstract.Storage.STORAGE) -> sig
  type address = Concepts.Hash.hash

  type 'a node

  val find : S.connection -> address -> 'a node

  val hash_of : 'a node -> address

  val insert : S.connection -> 'a node -> 'a key -> address -> ('a node, Concepts.Condition.condition) result
  val remove : S.connection -> 'a node -> 'a key -> ('a node, Concepts.Condition.condition) result
  val lookup : S.connection -> 'a node -> 'a key -> (address option, Concepts.Condition.condition) result
end

module Make (S : Abstract.Storage.STORAGE) = struct
  type address = Concepts.Hash.hash

  type 'a node =
    { keys : 'a key BatFingerTree.t;
      values : address BatFingerTree.t;
      children : address BatFingerTree.t }

  let rec lookup1 keys key bottom top =
  if bottom >= top then (bottom, false)
  else
    let mid = bottom + (top - bottom) / 2 in
    let node = BatFingerTree.get keys mid in
    match node#compare key with
    | Equal -> (mid, true)
    | Greater -> lookup1 keys key bottom mid
    | Smaller -> lookup1 keys key (mid + 1) top

  let is_leaf ({ children; _ } : 'a node) =
    0 = BatFingerTree.size children

  let child_of conn node i = failwith "TODO"

  let rec lookup conn ({ keys; values; _ } as node) key =
    let open Utilities.Result in
    let i, found = lookup1 keys key 0 (BatFingerTree.size keys) in
    if found then
      Ok (Some (BatFingerTree.get values i))
    else if is_leaf node then
      Ok None
    else
      let* child = child_of conn node i in
      lookup conn child key

  let insert conn node key value = failwith "TODO"

  let remove conn node key = failwith "TODO"

  let lookup conn node key = failwith "TODO"
end
