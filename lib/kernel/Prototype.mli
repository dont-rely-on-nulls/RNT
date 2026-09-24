val mixture_of : 'a -> (('a -> Protocols.Handle.t) -> 'a -> Protocols.Handle.protocol list) -> Protocols.Handle.t
val mixture : Protocols.Handle.protocol list -> Protocols.Handle.t

module Directory : sig
  val of_properties : (string * Protocols.Handle.t) list -> Protocols.Handle.protocol

  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY with type t = string) (V : Merkle.VALUE) : sig
    module Tree : module type of Merkle.Interface (S) (K) (V)
    val make : storage:S.connection -> constructor:(V.t -> (Protocols.Handle.t, Concepts.Condition.condition) result) -> node:Tree.node -> Protocols.Handle.protocol
  end
end

module Associative : sig
  val of_properties : (string * (Protocols.Handle.t option -> (Protocols.Handle.t, Concepts.Condition.condition) result)) list -> Protocols.Handle.protocol

  val update_only : (Protocols.Handle.t -> (Protocols.Handle.t, Concepts.Condition.condition) result) -> (Protocols.Handle.t option -> (Protocols.Handle.t, Concepts.Condition.condition) result)

  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY with type t = string) : sig
    module Tree : module type of Merkle.Make (S) (K)
    val make : storage:S.connection -> constructor:(Tree.node -> (Protocols.Handle.t, Concepts.Condition.condition) result) -> node:Tree.node -> Protocols.Handle.protocol
  end
end

module Addressable : sig
  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY) : sig
    module Tree : module type of Merkle.Make (S) (K)
    val make : node:Tree.node -> Protocols.Handle.protocol
  end
end
