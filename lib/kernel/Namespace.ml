class namespace = object (self)
  inherit Lifecycle.null
  inherit Identity.of_id

  val entries : (string, Protocols.Handle.t) BatMap.t Atomic.t =
    Atomic.make BatMap.empty

  method protocols = Protocols.[Directory.make self; Registry.make self]

  method update key reference value =
    match
      Utilities.Atomic.mswap entries
        (fun e ->
          if BatMap.find_opt key e = reference then
            match value with
            | Some v -> Ok (BatMap.add key v e)
            | None -> Ok (BatMap.remove key e)
          else
            Error ())
    with
    | Ok _ -> Ok true
    | Error _ -> Ok false

  method list =
    Atomic.get entries
    |> BatMap.keys
    |> BatFingerTree.of_enum
    |> Result.ok

  method find key =
    Atomic.get entries
    |> BatMap.find_opt key
    |> Utilities.Option.fmap Protocols.Handle.copy
    |> Result.ok
end

let make () = Protocols.Handle.make (new namespace)
