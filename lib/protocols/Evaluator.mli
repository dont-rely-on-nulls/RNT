type t

(** [within] is the directory the program's paths resolve against: the
    branch state a stored program was read through, or whatever part of
    the tree a caller hands over. *)
class type implementation = object
  method invoke : Handle.t -> within:Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result

val invoke :
  t Handle.interface ->
  Handle.t ->
  within:Handle.t ->
  (Handle.t, Concepts.Condition.condition) result
