(* @needs Value *)

type hash = Digestif.SHA256.t

let size = 256/8

let compare h1 h2 = Digestif.SHA256.unsafe_compare h1 h2
                    |> Ordering.of_int

let hash_of_value (v : Value.value) =
  Representation.(blob_of_value v |> bytes_of_blob) |> Digestif.SHA256.digest_bytes

let hash_of_bytes bytes = Digestif.SHA256.digest_bytes bytes

let hash_equals = Digestif.SHA256.equal
let bytes_of_hash (h : hash) = Bytes.of_string (Digestif.SHA256.to_raw_string h)

let power_of_two p =
  let b = Bytes.make 32 '\x00' in
  let byte = 31 - (p / 8) in
  Bytes.set b byte (Char.chr (1 lsl (p mod 8)));
  Bytes.unsafe_to_string b

let pick n hash =
  let threshold = Digestif.SHA256.of_raw_string (power_of_two (256 - n)) in
  compare hash threshold = Ordering.Smaller
