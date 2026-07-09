(** An abstract value representing a hash *)
type hash

(** Given a value, compute it's hash *)
val hash_of_value: Value.value -> hash

(** Given two hashes, are they the same? *)
val hash_equals: hash -> hash -> bool
