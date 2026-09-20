type t = Empty | Bounded of int | Finite | Countable

val bounded : int -> t
val compare : t -> t -> Utilities.Ordering.t
val equal : t -> t -> bool
val leq : t -> t -> bool
val join : t -> t -> t
val meet : t -> t -> t

(** the class of a generator run under every binding produced by
    another, which is how the classes of the generators chosen by an
    analysis combine. *)
val product : t -> t -> t
val exhaustible : t -> bool
val to_string : t -> string
