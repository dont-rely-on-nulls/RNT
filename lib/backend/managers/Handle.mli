module type HANDLER = sig
  type t

  type handle

  type cursor

  val open_ :
    t ->
    Permission.capability ->
    path:Permission.path ->
    claim:Permission.claim ->
    (handle, Concepts.Condition.condition) result

  val with_cursor :
    handle ->
    args:Concepts.Value.value BatFingerTree.t ->
    (cursor -> 'a) ->
    ('a, Concepts.Condition.condition) result

  val next : cursor -> (Concepts.Tuple.t option, Concepts.Condition.condition) result
end

module Make (Store : Abstract.Storage.STORAGE) : sig
  include HANDLER

  val create : Object.rnt_object_tree -> Store.transaction -> t

  val object_ : handle -> Object.registry

  val capability : handle -> Permission.capability
end
