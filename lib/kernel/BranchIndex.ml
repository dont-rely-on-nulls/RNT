type address = Concepts.Hash.hash
type root = address
type branch_name = string
type branch_state_root = address

let default_branch_name = "master"

module Branch_name = struct
  type t = branch_name

  let encode name = Concepts.Codec.Bencode.(String name |> to_blob)
  let compare left right = Concepts.Ordering.of_int (String.compare left right)

  let decode blob =
    Concepts.Codec.Bencode.of_blob blob |> Utilities.Result.fmap Concepts.Codec.Bencode.as_string
end

module Make (Store : Abstract.Storage.STORAGE) = struct
  module Tree = Merkle.Make (Store) (Branch_name)

  type tree = Tree.node

  let empty = Tree.empty
  let hash_of = Tree.hash_of
  let persist = Tree.persist
  let find = Tree.find
  let find_branch = Tree.lookup
  let put_branch = Tree.insert
end
