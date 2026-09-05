let mixture ps = Protocols.Handle.make @@
                   object
                     inherit Lifecycle.null
                     inherit Identity.of_id (* Should we allow the user to override this? *)

                     method protocols = ps
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
    module Interface = Merkle.Interface (S) (K) (V)
    module SI = Storage.Make (S)

    let make ~storage ~constructor ~node =
      Protocols.Directory.make @@
        object
          method list = SI.with_transaction storage (Fun.flip Interface.keys node)
          method find k = SI.with_transaction storage (fun tx -> Interface.lookup tx k node)
                          |> Result.map (Option.map constructor)
        end
  end
end
