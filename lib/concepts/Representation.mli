(** an abstract representation of an encoded value *)
type blob

(** encode a blob into a value *)
val blob_of_value: Value.value -> blob

(** decode a value from a blob *)
val value_of_blob: blob -> Value.value
