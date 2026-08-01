type address = Concepts.Hash.hash
type branch_index_root = address

val fixed_label : string
val fixed_label_address : address
val default_branch : string

module Make (Store : Abstract.Storage.STORAGE) : sig
  val read : Store.connection -> (branch_index_root option, Concepts.Condition.condition) result
  val initialize : Store.connection -> (branch_index_root, Concepts.Condition.condition) result
end
