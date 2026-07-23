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
    Leaf of
      { keys : 'a key BatFingerTree.t;
        values : address BatFingerTree.t }
  | Trunk of
      { keys : 'a key BatFingerTree.t;
        children : address BatFingerTree.t }

  let rec lookup1' keys key bottom top =
    if bottom >= top then (bottom, false)
    else
      let mid = bottom + (top - bottom) / 2 in
      let node = BatFingerTree.get keys mid in
      match node#compare key with
      | Equal -> (mid, true)
      | Greater -> lookup1' keys key bottom mid
      | Smaller -> lookup1' keys key (mid + 1) top

  let lookup1 keys key = lookup1' keys key 0 (BatFingerTree.size keys)

  let is_leaf = function
    | Leaf _ -> true
    | Trunk _ -> false

  let keys_of = function
    | Leaf { keys; _ } -> keys
    | Trunk { keys; _ } -> keys

  let find conn node = failwith "TODO"

  let rec lookup conn node key =
    let open Utilities.Result in
    let i, found = lookup1 (keys_of node) key in
    match node with
    | Leaf { values; _ } ->
       if found then Ok (Some (BatFingerTree.get values i)) else Ok None
    | Trunk { children; _ } ->
       let* child = BatFingerTree.get children (if found then i+1 else i) |> find conn in
       lookup conn child key

  let persist conn node = failwith "TODO"

  type 'a op = Update of address * 'a node | Split of address * 'a key * address

  let emplace i v ft =
    let fl, fr = BatFingerTree.split_at ft i in
    BatFingerTree.singleton v
    |> BatFingerTree.append fl
    |> (Fun.flip BatFingerTree.append) fr

  let insert1 node key value =
    let i, present = lookup1 (keys_of node) key in
    match node with
    | Leaf ({ keys; values } as leaf) ->
       if present then
         Leaf { leaf with values = BatFingerTree.set values i value }
       else
         Leaf { keys = emplace i key keys; values = emplace i value values }
    (* In danger or in doubt: run in circles, scream and shout. *)
    | Trunk _ -> failwith "Cannot insert a value on a trunk node. This is a bug in RNT!"

  let ceil a b = (a + b - 1) / b

  let pivot_at ft i =
    let l, r' = BatFingerTree.split_at ft i in
    let r, p = BatFingerTree.front_exn r' in
    l, p, r

  let should_split node = failwith "TODO"

  let split = function
    | Leaf { keys; values } ->
       let pivot = ceil (BatFingerTree.size keys) 2 in
       let kl, kr = BatFingerTree.split_at keys pivot in
       let vl, vr = BatFingerTree.split_at values pivot in
       let p = BatFingerTree.get kr 0 in
       Leaf { keys = kl; values = vl },
       p,
       Leaf { keys = kr; values = vr }
    | Trunk { keys; children } ->
       let pivot = ceil (BatFingerTree.size keys) 2 in
       let kl, kp, kr = pivot_at keys pivot in
       let cl, cr = BatFingerTree.split_at children (pivot + 1) in
       Trunk { keys = kl; children = cl },
       kp,
       Trunk { keys = kr; children = cr }

  let commit_node conn node =
    let open Utilities.Result in
    if should_split node then
      let l, p, r = split node in
      let* l_addr = persist conn l in
      let* r_addr = persist conn r in
      Ok (Split (l_addr, p, r_addr))
    else
      let* addr = persist conn node in
      Ok (Update (addr, node))

  let rec insert' conn node key value =
    let open Utilities.Result in
    match node with
    | Leaf _ ->
       insert1 node key value
       |> commit_node conn
    | Trunk { keys; children } ->
       let i, found = lookup1 keys key in
       let i = if found then i+1 else i in
       let* child = BatFingerTree.get children i |> find conn in
       let* r = insert' conn child key value in
       match r with
       | Update (addr, _) ->
          Trunk { keys; children = BatFingerTree.set children i addr }
          |> commit_node conn
       | Split (l, p, r) ->
          Trunk { keys = emplace i p keys;
                  children = BatFingerTree.set children i l |> emplace (i + 1) r }
          |> commit_node conn

  let insert conn node key value =
    let open Utilities.Result in
    let* op = insert' conn node key value in
    match op with
    | Update (_, node) -> Ok node
    | Split (l, p, r) ->
       let new_root =
         Trunk { keys = BatFingerTree.singleton p;
                 children = BatFingerTree.empty
                            |> (Fun.flip BatFingerTree.snoc) l
                            |> (Fun.flip BatFingerTree.snoc) r } in
       let* _ = persist conn new_root in
       Ok new_root

  let remove conn node key = failwith "TODO"
end
