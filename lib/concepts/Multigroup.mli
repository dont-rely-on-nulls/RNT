type t
type address = Hash.hash

include Object.S with type t := t

val make : name:string -> relations:address -> t
val name : t -> string
val relations : t -> address
