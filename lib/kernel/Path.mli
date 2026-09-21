type t

val this : t
val (@/) : string -> t -> t

(** the names a path is made of, in the order it walks them *)
val to_list : t -> string list

(** a path from the names it walks, the inverse of [to_list] *)
val of_list : string list -> t

(** do two paths walk the same names *)
val equal : t -> t -> bool

(** a path as a single name, with the separator escaped where a
    component contains it *)
val to_string : t -> string

val lookup : Protocols.Handle.t -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result

val update : Protocols.Handle.t -> t -> string -> Protocols.Handle.t option -> Protocols.Handle.t option -> (bool, Concepts.Condition.condition) result
