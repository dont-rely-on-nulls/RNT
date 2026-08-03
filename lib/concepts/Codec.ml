module Error = struct
  open Condition

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

  let trailing_bytes = condition "codec-trailing-bytes" "Bytes remain after a complete value" empty

  let tag_mismatch ~expected ~actual =
    condition "codec-tag-mismatch" "A value with a different tag was expected"
      ( "expected" |=| Value.String (String.make 1 expected)
      & "actual" |=| Value.String (String.make 1 actual) )

  let type_mismatch ~expected =
    condition "codec-type-mismatch" "A Bencode value of a different shape was expected"
      ("expected" |=| Value.String expected)

  let missing_field key =
    condition "codec-missing-field" "A required field is absent" ("field" |=| Value.String key)

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
  type t =
    | Tagged of char * t
    | Int of int
    | String of string
    | List of t list
    | Dict of (string * t) list

  let rec encode buf = function
    | Tagged (tag, value) -> Buffer.add_char buf 't'; Buffer.add_char buf tag; encode buf value
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
          (fun (k, v) -> encode buf (String k); encode buf v)
          (List.sort (fun (a, _) (b, _) -> String.compare a b) kvs);
        Buffer.add_char buf 'e'

  let to_bytes (value : t) : bytes =
    let buf = Buffer.create 256 in
    encode buf value; Buffer.to_bytes buf

  let as_string = function String s -> Ok s | _ -> Error (Error.type_mismatch ~expected:"string")
  let as_int = function Int n -> Ok n | _ -> Error (Error.type_mismatch ~expected:"integer")
  let as_list = function List l -> Ok l | _ -> Error (Error.type_mismatch ~expected:"list")
  let as_dict = function Dict d -> Ok d | _ -> Error (Error.type_mismatch ~expected:"dict")

  let of_bytes (bytes : bytes) : (t, Condition.condition) result =
    let open Utilities.Result in
    let s = Bytes.to_string bytes in
    let n = String.length s in
    let pos = ref 0 in
    let peek () = if !pos >= n then Error Error.unexpected_end else Ok s.[!pos] in
    let advance () = incr pos in
    (* Read the decimal run up to (and consuming) [term]. *)
    let read_int_from start term =
      let rec scan () =
        let* c = peek () in
        if c = term then begin
          let digits = String.sub s start (!pos - start) in
          advance ();
          match int_of_string_opt digits with
          | Some i -> Ok i
          | None -> Error (Error.malformed_integer digits)
        end
        else begin
          advance (); scan ()
        end
      in
      scan ()
    in
    let read_int term = read_int_from !pos term in
    let read_char () =
      let* c = peek () in
      advance (); Ok c
    in
    let rec parse () =
      let* c = peek () in
      advance ();
      match c with
      | 't' ->
          let* tag = read_char () in
          let* data = parse () in
          Ok (Tagged (tag, data))
      | 'i' ->
          let* n = read_int 'e' in
          Ok (Int n)
      | 'l' -> parse_list []
      | 'd' -> parse_dict []
      | c when c >= '0' && c <= '9' -> parse_string_from (!pos - 1)
      | c -> Error (Error.unexpected_byte c)
    and parse_string () = parse_string_from !pos
    and parse_string_from start =
      let* len = read_int_from start ':' in
      if len < 0 || !pos + len > n then Error (Error.string_out_of_bounds len)
      else
        let str = String.sub s !pos len in
        pos := !pos + len;
        Ok (String str)
    and parse_list acc =
      let* c = peek () in
      if c = 'e' then (
        advance ();
        Ok (List (List.rev acc)) )
      else
        let* result = parse () in
        parse_list (result :: acc)
    and parse_dict acc =
      let* c = peek () in
      if c = 'e' then (
        advance ();
        Ok (Dict (List.rev acc)) )
      else
        let* key = parse_string () in
        let* key = as_string key in
        let* value = parse () in
        parse_dict ((key, value) :: acc)
    in
    let* value = parse () in
    if !pos <> n then Error Error.trailing_bytes else Ok value

  let to_blob x = to_bytes x |> Representation.blob_of_bytes
  let of_blob b = Representation.bytes_of_blob b |> of_bytes

  let with_tag t = function
    | Tagged (t', v) -> if t = t' then Ok v else Error (Error.tag_mismatch ~expected:t ~actual:t')
    | _ -> Error (Error.type_mismatch ~expected:"tagged")

  let field key = function
    | Dict kvs -> (
      match List.assoc_opt key kvs with Some v -> Ok v | None -> Error (Error.missing_field key) )
    | _ -> Error (Error.type_mismatch ~expected:"dict")
end
