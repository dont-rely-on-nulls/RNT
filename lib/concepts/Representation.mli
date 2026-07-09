(** an abstract representation of an encoded value *)
type blob

(** encode a blob into a value *)
val blob_of_value: Value.value -> blob

(** decode a value from a blob *)
val value_of_blob: blob -> Value.value


(* TODO: see the comments on Backend.Storage.LMDB *)

(** create a blob from the data represented by bytes *)
val blob_of_bytes: bytes -> blob

(** return a bytes containing the data underlying a blob *)
val bytes_of_blob: blob -> bytes
