(** an abstract representation of an encoded value *)
type t

(* TODO: see the comments on Backend.Storage.LMDB *)

(** create a blob from the data represented by bytes *)
val blob_of_bytes : bytes -> t

(** return a bytes containing the data underlying a blob *)
val bytes_of_blob : t -> bytes

val create : int -> t

val set : t -> int -> char -> unit

val set_int64_be : t -> int -> int64 -> unit

val blit_string : string -> int -> t -> int -> int -> unit

val length : t -> int

val get : t -> int -> char

val sub_string : t -> int -> int -> string

val get_int64_be : t -> int -> int64
