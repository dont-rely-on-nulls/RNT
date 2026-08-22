module Errors = struct
  include Concepts.Condition

  let key_already_exists key =
    condition "key-already-exists" "The specified key already exists in the namespace"
      ("key" |=| Concepts.Value.String key)

  let no_such_key key =
    condition "no-such-key" "The specified key does not exist in the namespace"
      ("key" |=| Concepts.Value.String key)
end

class namespace = object (self)
  inherit Lifecycle.null

  val entries : (string, Protocols.Handle.t) BatMap.t Atomic.t =
    Atomic.make BatMap.empty

  method protocols = Protocols.[Directory.make self; Registry.make self]

  method register key value =
    Utilities.Atomic.mswap entries
      (fun e ->
        match BatMap.find_opt key e with
        | None -> Ok (BatMap.add key value e)
        | Some _ -> Error (Errors.key_already_exists key))
    |> Result.map ignore

  method unregister key =
    Utilities.Atomic.mswap entries
      (fun e ->
        try
          Ok (BatMap.remove_exn key e)
        with Not_found ->
          Error (Errors.no_such_key key))
    |> Result.map ignore

  method list =
    Atomic.get entries
    |> BatMap.keys
    |> BatList.of_enum

  method find key =
    Atomic.get entries
    |> BatMap.find_opt key
    |> Utilities.Option.fmap Protocols.Handle.copy
end

let make () = new namespace
