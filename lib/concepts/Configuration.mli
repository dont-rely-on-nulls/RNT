(** an abstract representation of a system configuration expression *)
type term

val tag_of: term -> (string, Condition.condition) result

(** an abstract type associating strings to configuration values *)
type dictionary

val value_for: string -> ?default:term -> dictionary -> (term, Condition.condition) result

val as_dictionary: term -> string -> (dictionary, Condition.condition) result
val as_int: term -> (int, Condition.condition) result
val as_string: term -> (string, Condition.condition) result
