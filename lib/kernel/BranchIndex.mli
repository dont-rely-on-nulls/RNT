type address = Concepts.Hash.hash
type root = address
type branch_name = string
type branch_state_root = address

val default_branch_name : branch_name

module Make (Store : Abstract.Storage.STORAGE) : sig
  type tree

  val empty : tree
  val empty_under : Store.transaction -> (address, Concepts.Condition.condition) result
  val hash_of : tree -> root
  val find : Store.transaction -> root -> (tree option, Concepts.Condition.condition) result

  val find_branch :
    Store.transaction ->
    branch_name ->
    tree ->
    (branch_state_root option, Concepts.Condition.condition) result

  val put_branch :
    Store.transaction ->
    branch_name ->
    branch_state_root ->
    tree ->
    (tree, Concepts.Condition.condition) result
end
