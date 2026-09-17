val resolve :
  Protocols.Context.t ->
  Kernel.Path.t ->
  (Protocols.Handle.t option, Concepts.Condition.condition) result

val over :
  snapshot:Concepts.Hash.hash ->
  root:Protocols.Handle.t ->
  ?cancelled:(unit -> bool) ->
  unit ->
  Protocols.Context.t
