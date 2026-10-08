module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)
  module B = Branch.Make (S)

  class session storage state =
    object (self)
      inherit Lifecycle.exclusive
      inherit Identity.of_id
      method to_string = "session"
      val storage : S.connection = storage
      val state : Protocols.Session.state Atomic.t = Atomic.make state
      method state = Atomic.get state
      method pin state' = Atomic.set state state'
      method protocols = Protocols.[Directory.make self; Session.make self]
      method list = Ok (BatFingerTree.singleton "branch")

      method find =
        function
        | "branch" ->
            SI.with_read storage (fun tx ->
                B.load tx storage (Atomic.get state).Protocols.Session.snapshot )
            |> Result.map Option.some
        | _ -> Ok None
    end

  let make storage state = new session storage state |> Protocols.Handle.make
end
