(** an abstract value representing a hash *)
type hash

(** given a value, compute it's hash *)
val hash_of_value : Value.value -> hash

(** given two hashes, are they the same? *)
val hash_equals : hash -> hash -> bool

(** given a hash, return a `bytes` representation of it *)
val bytes_of_hash : hash -> bytes
