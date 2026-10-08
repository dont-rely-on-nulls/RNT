module Make (S : Abstract.Storage.STORAGE) : sig
  val make : S.connection -> Protocols.Session.state -> Protocols.Handle.t
end
