 module Error = struct
  open Condition

  exception Condition of condition

  let signal (c : condition) : 'a = raise (Condition c)

  let attempt (f : unit -> 'a) : ('a, condition) result =
    try Ok (f ()) with Condition c -> Error c

  let unexpected_end =
    condition "codec-unexpected-end" "Unexpected end of input while decoding" empty

  let malformed_integer digits =
    condition "codec-malformed-integer" "A byte run is not a valid integer"
      ("digits" |=| Value.String digits)

  let unexpected_byte c =
    condition "codec-unexpected-byte" "Unexpected byte while decoding"
      ("byte" |=| Value.String (String.make 1 c))

  let string_out_of_bounds length =
    condition "codec-string-out-of-bounds" "A string length runs past the end of input"
      ("length" |=| Value.Integer length)

  let trailing_bytes =
    condition "codec-trailing-bytes" "Bytes remain after a complete value" empty

  let tag_mismatch ~expected ~actual =
    condition "codec-tag-mismatch" "A value with a different tag was expected"
      ("expected" |=| Value.String (String.make 1 expected) &
       "actual" |=| Value.String (String.make 1 actual))

  let type_mismatch ~expected =
    condition "codec-type-mismatch" "A Bencode value of a different shape was expected"
      ("expected" |=| Value.String expected)

  let missing_field key =
    condition "codec-missing-field" "A required field is absent"
      ("field" |=| Value.String key)

  let unexpected_object ~expected ~actual =
    condition "codec-unexpected-object" "The decoded object is not of the expected kind"
      ("expected" |=| Value.String expected & "actual" |=| Value.String actual)
end

(* A self-describing serialization used as the uniform wire format for
   durable objects. Chosen over an ad-hoc key=value scheme because it
   nests (a multigroup holds a map of relation hashes) and has a
   single byte form for a given value (dict keys are emitted sorted),
   which matters once these bytes are content-addressed.

   Grammar:
   - Int    "i" <decimal> "e" (negatives allowed)
   - String <length> ":" <raw bytes>
   - List   "l" <element>* "e"
   - Dict   "d" (<String key> <value>)* "e" keys sorted on encode *)
module Bencode = struct
  type t = Tagged of char * t | Int of int | String of string | List of t list | Dict of (string * t) list

  let rec encode buf = function
    | Tagged (tag, value) ->
       Buffer.add_char buf 't';
       Buffer.add_char buf tag;
       encode buf value
    | Int n ->
       Buffer.add_char buf 'i';
       Buffer.add_string buf (string_of_int n);
       Buffer.add_char buf 'e'
    | String s ->
       Buffer.add_string buf (string_of_int (String.length s));
       Buffer.add_char buf ':';
       Buffer.add_string buf s
    | List xs ->
       Buffer.add_char buf 'l';
       List.iter (encode buf) xs;
       Buffer.add_char buf 'e'
    | Dict kvs ->
       Buffer.add_char buf 'd';
       List.iter
         (fun (k, v) ->
           encode buf (String k);
           encode buf v )
         (List.sort (fun (a, _) (b, _) -> String.compare a b) kvs);
       Buffer.add_char buf 'e'

  let to_bytes (value : t) : bytes =
    let buf = Buffer.create 256 in
    encode buf value;
    Buffer.to_bytes buf

  let of_bytes (bytes : bytes) : t =
    let s = Bytes.to_string bytes in
    let n = String.length s in
    let pos = ref 0 in
    let peek () = if !pos >= n then Error.signal Error.unexpected_end else s.[!pos] in
    let advance () = incr pos in
    (* Read the decimal run up to (and consuming) [term]. *)
    let read_int term =
      let start = !pos in
      while peek () <> term do
        advance ()
      done;
      let digits = String.sub s start (!pos - start) in
      advance ();
      match int_of_string_opt digits with
      | Some i -> i
      | None -> Error.signal (Error.malformed_integer digits)
    in
    let read_char () = let c = peek () in advance (); c in
    let rec parse () =
      match peek () with
      | 't' -> advance (); Tagged (read_char (), parse ())
      | 'i' -> advance (); Int (read_int 'e')
      | 'l' -> advance (); parse_list []
      | 'd' -> advance (); parse_dict []
      | c when c >= '0' && c <= '9' -> parse_string ()
      | c -> Error.signal (Error.unexpected_byte c)
    and parse_string () =
      let len = read_int ':' in
      if len < 0 || !pos + len > n then Error.signal (Error.string_out_of_bounds len);
      let str = String.sub s !pos len in
      pos := !pos + len;
      String str
    and parse_list acc =
      if peek () = 'e' then (advance (); List (List.rev acc)) else parse_list (parse () :: acc)
    and parse_dict acc =
      if peek () = 'e' then (advance (); Dict (List.rev acc))
      else
        let key = match parse_string () with String k -> k | _ -> assert false in
        let value = parse () in
        parse_dict ((key, value) :: acc)
    in
    let value = parse () in
    if !pos <> n then Error.signal Error.trailing_bytes;
    value

  let to_blob x = to_bytes x |> Representation.blob_of_bytes
  let of_blob b = Representation.bytes_of_blob b |> of_bytes

  let as_string = function String s -> s | _ -> Error.signal (Error.type_mismatch ~expected:"string")
  let as_int = function Int n -> n | _ -> Error.signal (Error.type_mismatch ~expected:"integer")
  let as_list = function List l -> l | _ -> Error.signal (Error.type_mismatch ~expected:"list")
  let as_dict = function Dict d -> d | _ -> Error.signal (Error.type_mismatch ~expected:"dict")

  let with_tag t = function
    | Tagged (t', v) ->
       if t = t' then
         v
       else
         Error.signal (Error.tag_mismatch ~expected:t ~actual:t')
    | _ -> Error.signal (Error.type_mismatch ~expected:"tagged")

  let field key = function
    | Dict kvs -> (
      match List.assoc_opt key kvs with
      | Some v -> v
      | None -> Error.signal (Error.missing_field key) )
    | _ -> Error.signal (Error.type_mismatch ~expected:"dict")
end
