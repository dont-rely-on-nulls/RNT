type t
type address = Hash.hash
type schema

include Object.S with type t := t

val make : name:string -> tuples:address -> schema:schema -> t

val name : t -> string
val tuples : t -> address
val schema : t -> schema

val schema_empty : schema
val schema_of_list : (string * string) list -> schema
val schema_to_list : schema -> (string * string) list
