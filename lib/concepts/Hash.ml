(* @needs Value *)

type hash = Digestif.SHA256.t

let size = 256/8

let compare h1 h2 = Digestif.SHA256.unsafe_compare h1 h2
                    |> Utilities.Ordering.of_int

let hash_of_bytes bytes = Digestif.SHA256.digest_bytes bytes

let hash_of_blob blob = Blob.bytes_of_blob blob |> Digestif.SHA256.digest_bytes

let hash_of_int i =
  let b = Blob.create 8 in
  Blob.set_int64_be b 0 (Int64.of_int i);
  hash_of_blob b

let bytes_of_hash (h : hash) = Bytes.of_string (Digestif.SHA256.to_raw_string h)

let blob_of_hash h = bytes_of_hash h |> Blob.blob_of_bytes

let to_raw_string hash = Digestif.SHA256.to_raw_string hash

let of_raw_string str = Digestif.SHA256.of_raw_string str

let to_hum_string hash = Digestif.SHA256.to_hex hash

let hash_equals = Digestif.SHA256.equal

let power_of_two p =
  let b = Bytes.make 32 '\x00' in
  let byte = 31 - (p / 8) in
  Bytes.set b byte (Char.chr (1 lsl (p mod 8)));
  Bytes.unsafe_to_string b

let pick n hash =
  let threshold = Digestif.SHA256.of_raw_string (power_of_two (256 - n)) in
  compare hash threshold = Utilities.Ordering.Smaller
