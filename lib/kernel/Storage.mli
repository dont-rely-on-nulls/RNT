module Make : functor (S : Abstract.Storage.STORAGE) -> sig
  val finish : S.transaction -> ('a, Concepts.Condition.condition) result -> ('a, Concepts.Condition.condition) result
  val with_transaction : S.connection -> (S.transaction -> ('a, Concepts.Condition.condition) result) -> ('a, Concepts.Condition.condition) result
  val store_blob : S.transaction -> Concepts.Blob.t -> (Concepts.Hash.hash, Concepts.Condition.condition) result
end
