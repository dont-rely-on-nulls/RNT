(* @needs Value *)

(* The intent of this being an abstract type is to allow for switching
   the implementation to one backed by a C array later on, which would
   let us avoid copying when passing it through FFI boundaries. *)
type t = bytes

let blob_of_bytes (b : bytes) = b
let bytes_of_blob (b : t) = b
let create = Bytes.create
let set = Bytes.set
let set_int64_be = Bytes.set_int64_be
let blit_string = Bytes.blit_string
let length = Bytes.length
let get = Bytes.get
let sub_string = Bytes.sub_string
let get_int64_be = Bytes.get_int64_be
