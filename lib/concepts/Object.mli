type bencode = Codec.Bencode.t

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

module Field : sig
  val string : string -> bencode
  val address : Hash.hash -> bencode
  val require_string : string -> bencode -> (string, Condition.condition) result

  val require_address :
    malformed:(int -> Condition.condition) ->
    string ->
    bencode ->
    (Hash.hash, Condition.condition) result
end

module Codec : sig
  module type BODY = sig
    type t

    val tag : char
    val malformed : unit -> Condition.condition
    val equal : t -> t -> bool
    val fields : t -> (string * bencode) list
    val of_fields : bencode -> (t, Condition.condition) result
  end

  module Make (B : BODY) : S with type t = B.t
end
