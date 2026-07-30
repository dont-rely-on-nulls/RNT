type t
type address = Hash.hash

include Object.S with type t := t

val make : name:string -> target:address -> t

val name : t -> string
val target : t -> address
