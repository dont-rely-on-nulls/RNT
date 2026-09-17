type t

val this : t
val (@/) : string -> t -> t

val lookup : Protocols.Handle.t -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result

val update : Protocols.Handle.t -> t -> string -> Protocols.Handle.t option -> Protocols.Handle.t option -> (bool, Concepts.Condition.condition) result
