type t
type address = Hash.hash

include Object.S with type t := t

val make : current:address -> history:address -> tip:address option -> t

val current : t -> address
val history : t -> address
val tip : t -> address option
