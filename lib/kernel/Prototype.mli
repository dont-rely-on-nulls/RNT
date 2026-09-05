val mixture : Protocols.Handle.protocol list -> Protocols.Handle.t

module Directory : sig
  val of_properties : (string * Protocols.Handle.t) list -> Protocols.Handle.protocol

  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY with type t = string) (V : Merkle.VALUE) : sig
    module Interface : module type of Merkle.Interface (S) (K) (V)
    val make : storage:S.connection -> constructor:(V.t -> Protocols.Handle.t) -> node:(Interface.node) -> Protocols.Handle.protocol
  end
end
