type address = Concepts.Hash.hash

type t

val fixed_label : string
val fixed_label_address : address

include Concepts.Object.S with type t := t

val make : default_branch:string -> branches:address -> t

val default_branch : t -> string
val branches : t -> address
val address : t -> address

module Make (Store : Abstract.Storage.STORAGE) : sig
  val register : Store.transaction -> t -> (address, Concepts.Condition.condition) result
  val load : Store.transaction -> (t option, Concepts.Condition.condition) result
end
