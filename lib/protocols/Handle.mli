type t

type 'a interface

type protocol = ..

class type obj = object
  method reference : bool
  method release : unit
  method protocols : protocol list
end

val make : obj -> t

val into : t -> (protocol -> 'a option) -> 'a interface option

val invoke : 'a interface -> ('a -> 'b) -> 'b

val copy : t -> t option
val release : t -> unit
