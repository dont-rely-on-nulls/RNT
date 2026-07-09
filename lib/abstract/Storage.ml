module type STORAGE = sig
  type connection
  type transaction

  val connect: Concepts.Configuration.configuration -> connection

  (** begin a transaction within `connection` *)
  val start: connection -> transaction
  (** `commit` the current transaction *)
  val commit: transaction -> ()
  (** `abort` the current transaction *)
  val abort: transaction -> ()

  (** within a transaction, fetch a blob from disk *)
  val get: transaction -> Concepts.Hash.hash -> Concepts.Representation.blob
  (** within a transaction, associate a hash with a blob on disk *)
  val put: transaction -> Concepts.Hash.hash -> Concepts.Representation.blob -> ()
end
