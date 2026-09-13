type t

val this : t
val (@/) : string -> t -> t

val lookup : Protocols.Handle.t -> t -> (Protocols.Handle.t option, Concepts.Condition.condition) result
