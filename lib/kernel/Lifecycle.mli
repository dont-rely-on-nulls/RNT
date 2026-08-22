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
