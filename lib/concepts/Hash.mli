(** an abstract value representing a hash *)
type hash

(** the size of a hash, in bytes *)
val size : int

(** given a value, compute it's hash *)
val hash_of_value : Value.value -> hash

(** given a bag of bytes, compute it's hash *)
val hash_of_bytes : bytes -> hash

(** compare two hashes lexicographically *)
val compare : hash -> hash -> Ordering.ordering

(** given two hashes, are they the same? *)
val hash_equals : hash -> hash -> bool

(** given a hash, return a `bytes` representation of it *)
val bytes_of_hash : hash -> bytes

(** pick one every 1/2^n hashes *)
val pick : int -> hash -> bool
