module Error = struct
  open Concepts.Condition

  exception Condition of condition

  let signal (c : condition) : 'a = raise (Condition c)

  let attempt (f : unit -> 'a) : ('a, condition) result =
    try Ok (f ()) with Condition c -> Error c

  let unexpected_end =
    condition "codec-unexpected-end" "Unexpected end of input while decoding" empty

  let malformed_integer digits =
    condition "codec-malformed-integer" "A byte run is not a valid integer"
      ("digits" |=| Concepts.Value.String digits)

  let unexpected_byte c =
    condition "codec-unexpected-byte" "Unexpected byte while decoding"
      ("byte" |=| Concepts.Value.String (String.make 1 c))

  let string_out_of_bounds length =
    condition "codec-string-out-of-bounds" "A string length runs past the end of input"
      ("length" |=| Concepts.Value.Integer length)

  let trailing_bytes =
    condition "codec-trailing-bytes" "Bytes remain after a complete value" empty

  let type_mismatch ~expected =
    condition "codec-type-mismatch" "A Bencode value of a different shape was expected"
      ("expected" |=| Concepts.Value.String expected)

  let missing_field key =
    condition "codec-missing-field" "A required field is absent"
      ("field" |=| Concepts.Value.String key)

  let unexpected_object ~expected ~actual =
    condition "codec-unexpected-object" "The decoded object is not of the expected kind"
      ("expected" |=| Concepts.Value.String expected & "actual" |=| Concepts.Value.String actual)
end

(* Bencode: a small, canonical, self-describing serialization used as
   the uniform wire format for durable objects. Chosen over an ad-hoc
   key=value scheme because it nests (a multigroup holds a map of
   relation hashes), round-trips losslessly, and has a single
   canonical byte form for a given value (dict keys are emitted
   sorted), which matters once these bytes are content-addressed.     

   Grammar:
   - Int    "i" <decimal> "e" (negatives allowed)
   - String <length> ":" <raw bytes>
   - List   "l" <element>* "e"
   - Dict   "d" (<String key> <value>)* "e" keys sorted on encode *)
module Bencode = struct
  type t = Int of int | String of string | List of t list | Dict of (string * t) list

  let rec encode buf = function
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
    let rec parse () =
      match peek () with
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

  let as_string = function String s -> s | _ -> Error.signal (Error.type_mismatch ~expected:"string")
  let as_int = function Int n -> n | _ -> Error.signal (Error.type_mismatch ~expected:"integer")
  let as_list = function List l -> l | _ -> Error.signal (Error.type_mismatch ~expected:"list")
  let as_dict = function Dict d -> d | _ -> Error.signal (Error.type_mismatch ~expected:"dict")

  let field key = function
    | Dict kvs -> (
      match List.assoc_opt key kvs with
      | Some v -> v
      | None -> Error.signal (Error.missing_field key) )
    | _ -> Error.signal (Error.type_mismatch ~expected:"dict")
end

(* Codec represents the durable and in-memory representation of the
   objects the object manager only holds references to. The registry
   stores a bare reference (a Merkle root that is) to keep memory
   usage low; when a process first touches an object we decode its
   full form here, and the same decoded value is shared by every later
   reader (everything but branch tips is immutable, so sharing is
   safe).

   These records mirror the sakura domain classes, but flattened to
   plain data without methods, closures, etc. Only what must survive a
   round-trip through storage.  The wire format is Bencode so every
   record serializes uniformly. Hashes are hex strings, matching the
   merkle_root references carried in the object registry. *)

(* A multigroup keeps only the names and content hashes of its
   relations, not the relations themselves: the relation body is a
   separate object, resolved on demand through its hash. *)
module Multigroup = struct
  type t = {name: string; relations: string BatMap.String.t; timestamp: float}

  let to_bencode {name; relations; timestamp} : Bencode.t =
    Bencode.Dict
      [ ("type", String "multigroup");
        ("name", String name);
        ( "relations",
          Dict (BatMap.String.bindings relations |> List.map (fun (n, h) -> (n, Bencode.String h)))
        );
        ("timestamp", String (Printf.sprintf "%.17g" timestamp)) ]

  let of_bencode (b : Bencode.t) : t =
    (match Bencode.(field "type" b |> as_string) with
    | "multigroup" -> ()
    | actual -> Error.signal (Error.unexpected_object ~expected:"multigroup" ~actual));
    let relations =
      Bencode.(field "relations" b |> as_dict)
      |> List.fold_left
           (fun acc (n, h) -> BatMap.String.add n (Bencode.as_string h) acc)
           BatMap.String.empty
    in
    { name= Bencode.(field "name" b |> as_string);
      relations;
      timestamp= Bencode.(field "timestamp" b |> as_string) |> float_of_string }

  let to_bytes t = Bencode.to_bytes (to_bencode t)
  let of_bytes b = Error.attempt (fun () -> of_bencode (Bencode.of_bytes b))
end

(* A relation carries its identity (name + schema) and the merkle root
   of the prolly tree holding its tuples. The empty string means an
   empty relation for now. The schema maps each attribute name to its
   domain. Attribute order is not important, so it is kept as a map,
   not as a list. *)
module Relation = struct
  type t = {name: string; schema: string BatMap.String.t; tree_pointer: string}

  let to_bencode {name; schema; tree_pointer} : Bencode.t =
    Bencode.Dict
      [ ("type", String "relation");
        ("name", String name);
        ( "schema",
          Dict (BatMap.String.bindings schema |> List.map (fun (a, d) -> (a, Bencode.String d))) );
        ("tree_pointer", String tree_pointer) ]

  let of_bencode (b : Bencode.t) : t =
    (match Bencode.(field "type" b |> as_string) with
    | "relation" -> ()
    | actual -> Error.signal (Error.unexpected_object ~expected:"relation" ~actual));
    let schema =
      Bencode.(field "schema" b |> as_dict)
      |> List.fold_left
           (fun acc (a, d) -> BatMap.String.add a (Bencode.as_string d) acc)
           BatMap.String.empty
    in
    { name= Bencode.(field "name" b |> as_string);
      schema;
      tree_pointer= Bencode.(field "tree_pointer" b |> as_string) }

  let to_bytes t = Bencode.to_bytes (to_bencode t)
  let of_bytes b = Error.attempt (fun () -> of_bencode (Bencode.of_bytes b))
end
