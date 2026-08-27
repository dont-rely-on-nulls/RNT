module Make : functor (S : Abstract.Storage.STORAGE) -> sig
  module Pointer : sig
    type 'a t

    val make : S.address -> (S.transaction -> S.address -> ('a, Concepts.Condition.condition) result) -> 'a t
    val address_of : 'a t -> S.address
    val swap : 'a t -> S.address -> 'a t
    val deref : S.transaction -> 'a t -> ('a, Concepts.Condition.condition) result
  end

  val as_hash : S.address -> Concepts.Hash.hash

  val finish : S.transaction -> ('a, Concepts.Condition.condition) result -> ('a, Concepts.Condition.condition) result
  val with_transaction : S.connection -> (S.transaction -> ('a, Concepts.Condition.condition) result) -> ('a, Concepts.Condition.condition) result
  val store_blob : S.transaction -> Concepts.Blob.t -> (Concepts.Hash.hash, Concepts.Condition.condition) result
  val get_req: S.transaction -> S.address -> (Concepts.Blob.t, Concepts.Condition.condition) result
end
