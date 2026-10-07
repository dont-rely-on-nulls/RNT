module Make (S : Abstract.Storage.STORAGE) : sig
  val make :
    ?evaluators:Protocols.Handle.t -> S.connection -> Protocols.Session.state -> Protocols.Handle.t
end
