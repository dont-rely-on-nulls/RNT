type t

type 'a interface

type protocol = ..

class type obj = object
  method reference : bool
  method release : unit
  method hash : Concepts.Hash.hash
  method protocols : protocol list
end

val make : #obj -> t

val into : t -> (protocol -> 'a option) -> 'a interface option

val invoke : 'a interface -> ('a -> 'b) -> 'b

val copy : t -> t option
val equal : t -> t -> bool
val release : t -> unit
