class type lifecycle = object
  method reference : bool
  method release : unit
end

class type virtual controlled_lifecycle = object
  inherit lifecycle
  method virtual destroy : unit
end

class null =
  object
    method reference = true
    method release = ()
  end

class virtual counted =
  object (self)
    val references = Atomic.make 1
    method virtual destroy : unit
    method reference = Atomic.incr references; true
    method release = if Atomic.fetch_and_add references (-1) = 1 then self#destroy
  end

class retaining inner (owner : lifecycle) =
  object
    inherit counted
    initializer ignore owner#reference
    method destroy = Protocols.Handle.release inner; owner#release
    method hash = Protocols.Handle.hash inner
    method protocols = Protocols.Handle.protocols inner
  end
