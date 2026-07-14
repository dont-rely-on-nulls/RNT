module C = struct
  open Ctypes
  open Foreign

  type byte = Unsigned.UChar.t
  let byte = uchar

  type buffer = byte CArray.t

  let get b i = CArray.get b i

  let make size = CArray.make uchar size
end

type blob = C.buffer

type cursor = { buffer : blob; pos : int }
type 'a parser = cursor -> (('a * cursor), Condition.condition) result

type 'a reader = 'a parser
type 'a writer = 'a -> unit parser

type 'a view = 'a reader * 'a writer

type tag = Integer | String

let (tag_of_repr, repr_of_tag) = Utilities.enumeration [| Integer; String |]

let blob_of_value (_ : Value.value) = failwith "TODO"
let value_of_blob (_ : blob) = failwith "TODO"
let blob_of_bytes (_ : bytes) = failwith "TODO"
let bytes_of_blob (_ : blob) = failwith "TODO"
