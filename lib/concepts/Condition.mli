(** an abstract type representing an error condition *)
type condition

type ps

val ( |=| ): string -> Value.value -> ps
val ( & ): ps -> ps -> ps
val empty: ps

(** construct a condition out of a name, a message, a set of properties and an optional parent *)
val condition: string -> string -> ?parent:condition -> ps -> condition

(** print a condition to a human-readable string *)
val to_string_hum: condition -> string
