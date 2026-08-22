class type lifecycle = object
  method reference : bool
  method release : unit
end

class type virtual controlled_lifecycle = object
  inherit lifecycle
  method virtual destroy : unit
end

class null = object
  method reference = true
  method release = ()
end

class virtual counted = object (self)
  val references = Atomic.make 1

  method virtual destroy : unit

  method reference =
    Atomic.incr references;
    true

  method release =
    Atomic.decr references;
    if Atomic.get references <= 0 then
      self#destroy
end
