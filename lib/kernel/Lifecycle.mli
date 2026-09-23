class type lifecycle = object
  method reference : bool
  method release : unit
end

class type virtual controlled_lifecycle = object
  inherit lifecycle
  method virtual destroy : unit
end

class null : lifecycle
class virtual counted : controlled_lifecycle

(** stands for [inner], carrying what it carries, while holding a
    reference to [owner], so what [inner] reads outlives a release of
    the object that produced it. *)
class retaining : Protocols.Handle.t -> lifecycle -> object
  inherit lifecycle
  method destroy : unit
  method hash : Concepts.Hash.hash
  method protocols : Protocols.Handle.protocol list
end
