(** an abstract type representing an error condition *)
type condition

type ps

val ( |=| ): string -> Value.value -> ps
val ( & ): ps -> ps -> ps
val empty: ps

(** print a condition to a human-readable string *)
val to_string_hum: condition -> string
