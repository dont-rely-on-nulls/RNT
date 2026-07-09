type hash = bytes

let hash_of_value (_: Value.value) = failwith "TODO"

let hash_equals (_: hash) (_: hash) = failwith "TODO"

let bytes_of_hash (h: hash) = h
