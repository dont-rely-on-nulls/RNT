(** a tagged concrete value *)
type value
  = String of string
  | Integer of int

(** given a value, return a string representation of it *)
val to_string: value -> string

(** given two values, are they the same? *)
val equal: value -> value -> bool
