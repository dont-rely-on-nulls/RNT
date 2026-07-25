class type ['a] key = object
  method value : 'a
  method encode : Concepts.Representation.blob
  method compare : 'a key -> Concepts.Ordering.ordering
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
    Leaf of
      { keys : 'a key BatFingerTree.t;
        values : address BatFingerTree.t }
  | Trunk of
      { keys : 'a key BatFingerTree.t;
        children : address BatFingerTree.t }

  let rec lookup1' keys key bottom top =
    let open Concepts.Ordering in
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

  let find conn node = failwith "TODO" [@@warning "-27"]

  let rec lookup conn node key =
    let open Utilities.Result in
    let i, found = lookup1 (keys_of node) key in
    match node with
    | Leaf { values; _ } ->
       if found then Ok (Some (BatFingerTree.get values i)) else Ok None
    | Trunk { children; _ } ->
       let* child = BatFingerTree.get children (if found then i+1 else i) |> find conn in
       lookup conn child key

  let persist conn node = failwith "TODO" [@@warning "-27"]

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
    (* When in danger or in doubt: run in circles, scream and shout. *)
    | Trunk _ -> failwith "Cannot insert a value on a trunk node. This is a bug in RNT!"

  let ceil a b = (a + b - 1) / b

  let pivot_at ft i =
    let l, r' = BatFingerTree.split_at ft i in
    let r, p = BatFingerTree.front_exn r' in
    l, p, r

  let split_at pivot = function
    | Leaf { keys; values } ->
       let kl, kr = BatFingerTree.split_at keys pivot in
       let vl, vr = BatFingerTree.split_at values pivot in
       let p = BatFingerTree.get kr 0 in
       Leaf { keys = kl; values = vl },
       p,
       Leaf { keys = kr; values = vr }
    | Trunk { keys; children } ->
       let kl, kp, kr = pivot_at keys pivot in
       let cl, cr = BatFingerTree.split_at children (pivot + 1) in
       Trunk { keys = kl; children = cl },
       kp,
       Trunk { keys = kr; children = cr }

  (* FIXME: this works out to a geometric distribution with roughly 64
     keys per node. Some of the consequences of this are that:
     - most of our nodes will end up with one or a few elements, which
       would make our trees taller than they would normally need to be
     - some nodes will end up much larger than usual, which is bad for
       lookup performance

     What we want is a normal distribution centered around our desired
     node size. See
     https://www.dolthub.com/docs/architecture/storage-engine/prolly-tree/#controlling-chunk-size
   *)
  let should_split = Concepts.Hash.pick 6

  let hash_of_keys ks =
    let buffer = Buffer.create 1024 in
    BatFingerTree.iter
      (fun k ->
        k#encode
        |> Concepts.Representation.bytes_of_blob
        |> Buffer.add_bytes buffer)
      ks;
    Concepts.Hash.hash_of_bytes (Buffer.to_bytes buffer)

  let split_position keys =
    let rec loop left right =
      match BatFingerTree.front right with
      | None -> None
      | Some (tail, head) ->
         (* TODO: rolling hash *)
         let left' = BatFingerTree.snoc left head in
         let hash = hash_of_keys left' in
         if should_split hash then
           Some (BatFingerTree.size left)
         else
           loop left' tail
    in
    loop BatFingerTree.empty keys

  let commit_node conn node =
    let open Utilities.Result in
    match split_position (keys_of node) with
    | Some i ->
       let l, p, r = split_at i node in
       let* l_addr = persist conn l in
       let* r_addr = persist conn r in
       Ok (Split (l_addr, p, r_addr))
    | None ->
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

  let remove conn node key = failwith "TODO" [@@warning "-27"]
end
