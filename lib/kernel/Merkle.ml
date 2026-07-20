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

  let order = 4096              (* TODO: this likely warrants some benchmarking *)

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

  let find conn node = failwith "TODO"

  let rec lookup conn ({ keys; values; children } as node) key =
    let open Utilities.Result in
    let i, found = lookup1 keys key 0 (BatFingerTree.size keys) in
    if found then
      Ok (Some (BatFingerTree.get values i))
    else if is_leaf node then
      Ok None
    else
      let* child = BatFingerTree.get children i |> find conn in
      lookup conn child key

  let persist conn node = failwith "TODO"

  type 'a op = Update of address * 'a node | Split of address * 'a key * address * address

  let emplace i v ft =
    let fl, fr = BatFingerTree.split_at ft i in
    BatFingerTree.singleton v
    |> BatFingerTree.append fl
    |> (Fun.flip BatFingerTree.append) fr

  let insert_value ({ keys; values; _ } as node) key value =
    let i, present = lookup1 keys key 0 (BatFingerTree.size keys) in
    if present then
      { node with values = BatFingerTree.set values i value }
    else
      { node with keys = emplace i key keys; values = emplace i value values }

  let ceil a b = (a + b - 1) / b

  let pivot_at ft i =
    let l, r' = BatFingerTree.split_at ft i in
    let r, p = BatFingerTree.front_exn r' in
    l, p, r

  let split ({ keys; values; children }) =
    let pivot = ceil (BatFingerTree.size keys) 2 in
    let kl, kp, kr = pivot_at keys pivot in
    let vl, vp, vr = pivot_at values pivot in
    let pl, pr = BatFingerTree.split_at children (pivot + 1) in
    { keys = kl; values = vl; children = pl },
    kp, vp,
    { keys = kr; values = vr; children = pr }

  let commit_node conn ({ keys; _ } as node) =
    let open Utilities.Result in
    if order = BatFingerTree.size keys then
      let l, kp, vp, r = split node in
      let* l_addr = persist conn l in
      let* r_addr = persist conn r in
      Ok (Split (l_addr, kp, vp, r_addr))
    else
      let* addr = persist conn node in
      Ok (Update (addr, node))

  let rec insert' conn node key value =
    let open Utilities.Result in
    if is_leaf node then
      insert_value node key value
      |> commit_node conn
    else
      let i, present = lookup1 node.keys key 0 (BatFingerTree.size node.keys) in
      if present then
        insert_value node key value
        |> commit_node conn
      else
        let* child = BatFingerTree.get node.children i |> find conn in
        let* r = insert' conn child key value in
        match r with
        | Update (addr, _) ->
           { node with children = BatFingerTree.set node.children i addr }
           |> commit_node conn
        | Split (l, kp, vp, r) ->
           { keys = emplace i kp node.keys;
             values = emplace i vp node.values;
             children = BatFingerTree.set node.children i l |> emplace (i + 1) r }
           |> commit_node conn

  let remove conn node key = failwith "TODO"
end
