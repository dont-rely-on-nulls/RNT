(** an abstract value representing a hash *)
type hash

(** the size of a hash, in bytes *)
val size : int

(** given a bag of bytes, compute it's hash *)
val hash_of_bytes : bytes -> hash

(** given a blob, compute it's hash *)
val hash_of_blob : Blob.t -> hash

(** given a hash, return a representation of it as a string (/not/ the usual hex representation!) *)
val to_raw_string : hash -> string

(** given a string containing a representation of a hash (as per `to_raw_string`), return the corresponding hash *)
val of_raw_string : string -> hash

(** given a hash, return a representation of it as a string suitable for being displayed to humans *)
val to_hum_string : hash -> string

(** compare two hashes lexicographically *)
val compare : hash -> hash -> Ordering.ordering

(** given two hashes, are they the same? *)
val hash_equals : hash -> hash -> bool

(** given a hash, return a `bytes` representation of it *)
val bytes_of_hash : hash -> bytes

(** given a hash, return a `blob` representation of it *)
val blob_of_hash : hash -> Blob.t

(** pick one every 1/2^n hashes *)
val pick : int -> hash -> bool
