type hash = Digestif.SHA256.t

let hash_of_value (v : Value.value) =
  Representation.(blob_of_value v |> bytes_of_blob) |> Digestif.SHA256.digest_bytes

let hash_equals = Digestif.SHA256.equal
let bytes_of_hash (h : hash) = Bytes.of_string (Digestif.SHA256.to_raw_string h)
