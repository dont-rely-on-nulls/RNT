module type STORAGE = sig
  type connection
  type transaction

  val connect: Concepts.Configuration.configuration -> (connection, Concepts.Condition.condition) result

  (** begin a transaction within `connection` *)
  val start: connection -> (transaction, Concepts.Condition.condition) result

  (** `commit` the current transaction *)
  val commit: transaction -> (unit, Concepts.Condition.condition) result

  (** `abort` the current transaction *)
  val abort: transaction -> (unit, Concepts.Condition.condition) result

  (** within a transaction, fetch a blob from disk *)
  val get: transaction -> Concepts.Hash.hash -> (Concepts.Representation.blob option, Concepts.Condition.condition) result

  (** within a transaction, associate a hash with a blob on disk *)
  val put: transaction -> Concepts.Hash.hash -> Concepts.Representation.blob -> (unit, Concepts.Condition.condition) result
end
