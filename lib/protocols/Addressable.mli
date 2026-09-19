type t

class type implementation = object
  method address : Concepts.Hash.hash
end

val make : #implementation -> Handle.protocol

val from : Handle.t -> t Handle.interface option

val address : t Handle.interface -> Concepts.Hash.hash
