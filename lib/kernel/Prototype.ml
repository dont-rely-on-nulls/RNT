let mixture ps = Protocols.Handle.make @@
                   object
                     inherit Lifecycle.null
                     inherit Identity.of_id (* Should we allow the user to override this? *)

                     method protocols = ps
                   end

let rec mixture_of value f =
  mixture (f (fun value' -> mixture_of value' f) value)

module Associative = struct
  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY with type t = string) = struct
    module Tree = Merkle.Make (S) (K)
    module SI = Storage.Make (S)

    let make ~storage ~constructor ~node =
      Protocols.Associative.make @@
        object
          method update key value =
            (* TODO: read-only transactions *)
            SI.with_transaction storage (fun tx ->
                let open Utilities.Result in
                let open Protocols in
                let* node' = match value with
                  | None -> Tree.remove tx key node
                  | Some h ->
                     let* addressable = Handle.require Addressable.from h in
                     let addr = Addressable.address addressable in
                     Tree.insert tx key addr node
                in
                constructor node')
        end
  end
end

module Directory = struct
  let of_properties (props) =
    Protocols.Directory.make @@
      object
        val props = BatList.to_seq props |> BatMap.of_seq

        method list = Ok (BatMap.keys props |> BatFingerTree.of_enum)
        method find k = Ok (BatMap.find_opt k props)
      end

  module OfTree (S : Abstract.Storage.STORAGE) (K : Merkle.KEY with type t = string) (V : Merkle.VALUE) = struct
    module Tree = Merkle.Interface (S) (K) (V)
    module SI = Storage.Make (S)

    let make ~storage ~constructor ~node =
      Protocols.Directory.make @@
        object
          method list = SI.with_transaction storage (Fun.flip Tree.keys node)
          method find k = SI.with_transaction storage (fun tx -> Tree.lookup tx k node)
                          |> Utilities.Result.fmap (function
                                 | None -> Ok None
                                 | Some x -> constructor x |> Result.map (Option.some))
        end
  end
end
