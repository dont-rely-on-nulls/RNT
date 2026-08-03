type bencode = Codec.Bencode.t

module Bencode = Codec.Bencode

module type S = sig
  type t

  val equal : t -> t -> bool
  val to_bencode : t -> bencode
  val of_bencode : bencode -> (t, Condition.condition) result
  val to_blob : t -> Representation.blob
  val of_blob : Representation.blob -> (t, Condition.condition) result
  val to_bytes : t -> bytes
  val of_bytes : bytes -> (t, Condition.condition) result
end

module type OBJECT = S

module Field = struct
  let string value = Bencode.String value
  let address address = Bencode.String (Hash.to_raw_string address)

  let require_string key data =
    Codec.Bencode.field key data |> Utilities.Result.fmap Codec.Bencode.as_string

  let require_address ~malformed key data =
    let open Utilities.Result in
    let* raw = require_string key data in
    if String.length raw = Hash.size then Ok (Hash.of_raw_string raw)
    else Error (malformed (String.length raw))
end

module Codec = struct
  module type BODY = sig
    type t

    val tag : char
    val malformed : unit -> Condition.condition
    val equal : t -> t -> bool
    val fields : t -> (string * bencode) list
    val of_fields : bencode -> (t, Condition.condition) result
  end

  module Make (B : BODY) = struct
    type t = B.t

    let equal = B.equal
    let to_bencode object_ = Bencode.Tagged (B.tag, Bencode.Dict (B.fields object_))

    let of_bencode = function
      | Bencode.Tagged (tag, (Bencode.Dict _ as data)) when Char.equal tag B.tag -> B.of_fields data
      | _ -> Error (B.malformed ())

    let to_blob object_ = to_bencode object_ |> Bencode.to_blob
    let of_blob blob = Bencode.of_blob blob |> Utilities.Result.fmap of_bencode
    let to_bytes object_ = to_blob object_ |> Representation.bytes_of_blob
    let of_bytes bytes = Bencode.of_bytes bytes |> Utilities.Result.fmap of_bencode
  end
end
