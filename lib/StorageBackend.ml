module type T = sig
  val put : bytes -> string
  val get : string -> bytes option
end

module SQLite : T = struct
  let put (_value : bytes) = failwith "NOT IMPLEMENTED"
  let get (_hash : string) = failwith "NOT IMPLEMENTED"
end
