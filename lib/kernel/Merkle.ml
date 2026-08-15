module type VALUE = sig
  type t

  val encode : t -> Concepts.Representation.blob
  val decode : Concepts.Representation.blob -> (t, Concepts.Condition.condition) result
end

module type KEY = sig
  include VALUE

  val compare : t -> t -> Concepts.Ordering.ordering
end

module type TREE = functor (S : Abstract.Storage.STORAGE) (K : KEY) -> sig
  type address = Concepts.Hash.hash

  type node

  val find : S.transaction -> address -> (node option, Concepts.Condition.condition) result

  val empty : node
  val empty_under : S.transaction -> (address, Concepts.Condition.condition) result

  val hash_of : node -> address

  val insert : S.transaction -> K.t -> address -> node -> (node, Concepts.Condition.condition) result
  val remove : S.transaction -> K.t -> node -> (node, Concepts.Condition.condition) result
  val lookup : S.transaction -> K.t -> node -> (address option, Concepts.Condition.condition) result
end

module Make : TREE = functor (S : Abstract.Storage.STORAGE) (K : KEY) -> struct
  type address = Concepts.Hash.hash

  module Error = struct
    open Concepts.Condition

    let malformed_node () = condition "malformed-node" "A node representation did not conform to what was expected" empty
  end

  type node =
    Leaf of
      { keys : K.t BatFingerTree.t;
        values : address BatFingerTree.t }
  | Trunk of
      { keys : K.t BatFingerTree.t;
        children : address BatFingerTree.t }

  let empty = Leaf { keys = BatFingerTree.empty; values = BatFingerTree.empty }

  let rec lookup1' keys key bottom top =
    let open Concepts.Ordering in
    if bottom >= top then (bottom, false)
    else
      let mid = bottom + (top - bottom) / 2 in
      let node = BatFingerTree.get keys mid in
      match K.compare node key with
      | Equal -> (mid, true)
      | Greater -> lookup1' keys key bottom mid
      | Smaller -> lookup1' keys key (mid + 1) top

  let lookup1 keys key = lookup1' keys key 0 (BatFingerTree.size keys)

  let keys_of = function
    | Leaf { keys; _ } -> keys
    | Trunk { keys; _ } -> keys

  let of_bencode =
    let open Concepts.Codec.Bencode in
    let open Utilities.Result in
    (* This is terrible *)
    let decode_key t = as_string t
                       |> Result.map String.to_bytes
                       |> Result.map Concepts.Representation.blob_of_bytes
                       |> fmap K.decode in
    let decode_value t = as_string t |> Result.map Concepts.Hash.of_raw_string in
    let decode_list f data = data
                             |> fmap as_list
                             |> Result.map (List.map f)
                             |> fmap sequence
                             |> Result.map BatFingerTree.of_list in
    function
    | Tagged ('!', (Dict _ as data)) ->
       let* keys = field "keys" data |> decode_list decode_key in
       let* values = field "values" data |> decode_list decode_value in
       Ok (Leaf { keys; values })
    | Tagged ('#', (Dict _ as data)) ->
       let* keys = field "keys" data |> decode_list decode_key in
       let* children = field "children" data |> decode_list decode_value in
       Ok (Trunk { keys; children })
    | _ -> Error (Error.malformed_node ())

  let from_blob blob = Concepts.Codec.Bencode.of_blob blob
                       |> Utilities.Result.fmap of_bencode

  let to_bencode =
    let open Concepts.Codec.Bencode in
    (* Ditto. *)
    let bencode_key k = K.encode k
                        |> Concepts.Representation.bytes_of_blob
                        |> String.of_bytes
                        |> (fun s -> String s) in
    let bencode_hash h = String (Concepts.Hash.to_raw_string h) in
    function
    | Leaf { keys; values } ->
       Tagged ('!', Dict [("keys", List (BatFingerTree.to_list keys |> List.map bencode_key));
                          ("values", List (BatFingerTree.to_list values |> List.map bencode_hash))])
    | Trunk { keys; children } ->
       Tagged ('#', Dict [("keys", List (BatFingerTree.to_list keys |> List.map bencode_key));
                          ("children", List (BatFingerTree.to_list children |> List.map bencode_hash))])

  let to_blob node = to_bencode node |> Concepts.Codec.Bencode.to_blob

  (* TODO: we should probably cache this inside the node itself rather
     than recalculating it every time. We could also allow the user to
     create "uninterned" nodes that are not storage-backed, that could
     be used for intermediates and the like. *)
  let hash_of node = to_blob node |> Concepts.Hash.hash_of_blob

  let find tx node =
    let open Utilities.Result in
    let* data = S.get tx (S.Hash node) in
    match data with
    | None -> Ok None
    | Some data ->
       let* node = from_blob data in
       Ok (Some node)

  let find' tx node =
    let open Utilities.Result in
    let* child = find tx node in
    match child with
    | Some child -> Ok child
    | None -> failwith "A child node was not found on the underlying storage. Either your database is corrupted, or this is a bug on RNT!"

  let rec lookup tx key node =
    let open Utilities.Result in
    let i, found = lookup1 (keys_of node) key in
    match node with
    | Leaf { values; _ } ->
       if found then Ok (Some (BatFingerTree.get values i)) else Ok None
    | Trunk { children; _ } ->
       let* child = BatFingerTree.get children (if found then i+1 else i) |> find' tx in
       lookup tx key child

  let persist tx node =
    let open Utilities.Result in
    let data = to_blob node in
    let addr = Concepts.Hash.hash_of_blob data in
    let* () = S.put tx (S.Hash addr) data in
    Ok addr

  let empty_under tx = persist tx empty

  type op = Update of address * node | Split of address * K.t * address

  let emplace i v ft =
    let size = BatFingerTree.size ft in
    if i < 0 || i > size then
      invalid_arg "Merkle.emplace: index out of bounds"
    else if size = 0 then
      BatFingerTree.singleton v
    else if i = size then
      BatFingerTree.snoc ft v
    else
      let fl, fr = BatFingerTree.split_at ft i in
      BatFingerTree.singleton v
      |> BatFingerTree.append fl
      |> (Fun.flip BatFingerTree.append) fr

  let insert1 key value node =
    let i, present = lookup1 (keys_of node) key in
    match node with
    | Leaf ({ keys; values } as leaf) ->
       if present then
         Leaf { leaf with values = BatFingerTree.set values i value }
       else
         Leaf { keys = emplace i key keys; values = emplace i value values }
    (* When in danger or in doubt: run in circles, scream and shout. *)
    | Trunk _ -> failwith "Cannot insert a value on a trunk node. This is a bug in RNT!"

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
        K.encode k
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

  let commit_node tx node =
    let open Utilities.Result in
    match split_position (keys_of node) with
    | Some i ->
       let l, p, r = split_at i node in
       let* l_addr = persist tx l in
       let* r_addr = persist tx r in
       Ok (Split (l_addr, p, r_addr))
    | None ->
       let* addr = persist tx node in
       Ok (Update (addr, node))

  let rec insert' tx key value node =
    let open Utilities.Result in
    match node with
    | Leaf _ ->
       insert1 key value node
       |> commit_node tx
    | Trunk { keys; children } ->
       let i, found = lookup1 keys key in
       let i = if found then i+1 else i in
       let* child = BatFingerTree.get children i |> find' tx in
       let* r = insert' tx key value child in
       match r with
       | Update (addr, _) ->
          Trunk { keys; children = BatFingerTree.set children i addr }
          |> commit_node tx
       | Split (l, p, r) ->
          Trunk { keys = emplace i p keys;
                  children = BatFingerTree.set children i l |> emplace (i + 1) r }
          |> commit_node tx

  let insert tx key value node =
    let open Utilities.Result in
    let* op = insert' tx key value node in
    match op with
    | Update (_, node) -> Ok node
    | Split (l, p, r) ->
       let new_root =
         Trunk { keys = BatFingerTree.singleton p;
                 children = BatFingerTree.empty
                            |> (Fun.flip BatFingerTree.snoc) l
                            |> (Fun.flip BatFingerTree.snoc) r } in
       let* _ = persist tx new_root in
       Ok new_root

  let remove tx key node = failwith "TODO" [@@warning "-27"]
end

module type INTERFACE = functor (S : Abstract.Storage.STORAGE) (K : KEY) (V : VALUE) -> sig
  type address = Concepts.Hash.hash
  type node

  val find : S.transaction -> address -> (node option, Concepts.Condition.condition) result

  val empty : node

  val hash_of : node -> address

  val insert : S.transaction -> K.t -> V.t -> node -> (node, Concepts.Condition.condition) result
  val remove : S.transaction -> K.t -> node -> (node, Concepts.Condition.condition) result
  val lookup : S.transaction -> K.t -> node -> (V.t option, Concepts.Condition.condition) result
end

module Interface : INTERFACE = functor (S : Abstract.Storage.STORAGE) (K : KEY) (V : VALUE) -> struct
  module T = Make (S) (K)

  type address = T.address
  type node = T.node

  open Utilities.Result

  let intern tx v =
    let data = V.encode v in
    let addr = Concepts.Hash.hash_of_blob data in
    let* () = S.put tx (S.Hash addr) data in
    Ok addr

  let retrieve tx addr =
    let* data = S.get tx (S.Hash addr) in
    match data with
    | None -> Ok None
    | Some data ->
       let* v = V.decode data in
       Ok (Some v)

  let find = T.find
  let empty = T.empty
  let hash_of = T.hash_of

  let insert tx k v node =
    let* addr = intern tx v in
    T.insert tx k addr node

  let remove = T.remove

  let lookup tx k node =
    let* addr = T.lookup tx k node in
    match addr with
    | None -> Ok None
    | Some addr -> retrieve tx addr

end

module StringKey : KEY with type t = string = struct
  type t = string

  let encode s = String.to_bytes s |> Concepts.Representation.blob_of_bytes
  let compare s1 s2 = String.compare s1 s2 |> Concepts.Ordering.of_int
  let decode b = Concepts.Representation.bytes_of_blob b |> String.of_bytes |> Result.ok
end
