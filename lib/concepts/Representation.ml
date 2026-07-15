type blob = bytes

let blob_of_bytes (b : bytes) = b
let bytes_of_blob (b : blob) = b

(* A blob is a one-byte constructor tag followed by its payload. The
   tag makes the encoding self-describing so [value_of_blob] can
   recover the constructor:
   - String  ['\000'] ++ raw utf-8 bytes
   - Integer ['\001'] ++ 8-byte big-endian int64 *)
let tag_string = '\000'
let tag_integer = '\001'

let blob_of_value = function
  | Value.String s ->
      let b = Bytes.create (1 + String.length s) in
      Bytes.set b 0 tag_string;
      Bytes.blit_string s 0 b 1 (String.length s);
      b
  | Value.Integer n ->
      let b = Bytes.create 9 in
      Bytes.set b 0 tag_integer;
      Bytes.set_int64_be b 1 (Int64.of_int n);
      b

let value_of_blob (b : blob) =
  let n = Bytes.length b in
  if n = 0 then invalid_arg "value_of_blob: empty blob";
  match Bytes.get b 0 with
  | c when c = tag_string -> Value.String (Bytes.sub_string b 1 (n - 1))
  | c when c = tag_integer ->
      if n <> 9 then invalid_arg "value_of_blob: malformed integer payload";
      Value.Integer (Int64.to_int (Bytes.get_int64_be b 1))
  | c -> invalid_arg (Printf.sprintf "value_of_blob: unknown tag %C" c)
