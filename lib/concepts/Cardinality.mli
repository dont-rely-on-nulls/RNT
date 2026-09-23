type t = Empty | Bounded of int | Finite | Countable

val bounded : int -> t
val compare : t -> t -> Utilities.Ordering.t
val equal : t -> t -> bool
val leq : t -> t -> bool
val meet : t -> t -> t
val exhaustible : t -> bool
val to_string : t -> string
