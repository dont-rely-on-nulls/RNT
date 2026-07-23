(* @needs Value *)

type hash = Digestif.SHA256.t

let compare h1 h2 = Bytes.compare
                      Representation.(blob_of_value h1 |> bytes_of_blob)
                      Representation.(blob_of_value h2 |> bytes_of_blob)
                    |> Ordering.of_int

let hash_of_value (v : Value.value) =
  Representation.(blob_of_value v |> bytes_of_blob) |> Digestif.SHA256.digest_bytes

let hash_equals = Digestif.SHA256.equal
let bytes_of_hash (h : hash) = Bytes.of_string (Digestif.SHA256.to_raw_string h)
