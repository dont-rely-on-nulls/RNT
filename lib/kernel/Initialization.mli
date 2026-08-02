type address = Concepts.Hash.hash
type branch_index_root = address

val fixed_label : string
val fixed_label_address : address

module Make (Store : Abstract.Storage.STORAGE) : sig
  val initialize : Store.connection -> (branch_index_root, Concepts.Condition.condition) result
end
