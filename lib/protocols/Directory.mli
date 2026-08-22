type t

class type implementation = object
  method list : string list
  method find : string -> Handle.t option
end

val make : implementation -> Handle.protocol

val from : Handle.t -> t Handle.interface option

val list : t Handle.interface -> string list
val find : t Handle.interface -> string -> Handle.t option
