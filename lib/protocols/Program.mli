module type PROGRAM = sig
  type t
end

module Make (P : PROGRAM) : sig
  type t

  class type implementation = object
    method invoke :
      program:P.t ->
      Context.t ->
      (Handle.t, Concepts.Condition.condition) result
  end

  val make : #implementation -> Handle.protocol
  val from : Handle.t -> t Handle.interface option

  val invoke :
    t Handle.interface ->
    program:P.t ->
    Context.t ->
    (Handle.t, Concepts.Condition.condition) result
end
