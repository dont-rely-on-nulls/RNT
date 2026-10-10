type t
type 'a interface
type protocol = ..

class type obj = object
  method reference : bool
  method release : unit
  method is_managed : bool
  method hash : Concepts.Hash.hash
  method to_string : string
  method protocols : protocol list
end

val make : #obj -> t
val into : t -> (protocol -> 'a option) -> 'a interface option
val from : 'a interface -> t
val invoke : 'a interface -> ('a -> 'b) -> 'b
val copy : t -> t option
val move : t -> t
val equal : t -> t -> bool
val release : t -> unit
val hash : t -> Concepts.Hash.hash
val protocols : t -> protocol list
val to_string : t -> string
val require : (t -> 'a interface option) -> t -> ('a interface, Concepts.Condition.condition) result
val with_autorelease : (unit -> 'a) -> 'a
val without_autorelease : (unit -> 'a) -> 'a
val autorelease : t -> unit
val keep : t -> unit
