class namespace : object
  inherit Protocols.Handle.obj
  inherit Protocols.Directory.implementation
  inherit Protocols.Registry.implementation
end

val make : unit -> Protocols.Handle.t
