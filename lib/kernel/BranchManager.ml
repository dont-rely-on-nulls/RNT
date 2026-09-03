module Error = struct
  open Concepts.Condition

  let invalid_root head =
    condition "invalid-root" "The root hash for the database state is missing from the backend. Either your storage is corrupted, or this is a bug in RNT!"
      ("hash" |=| (Concepts.Value.String (Concepts.Hash.to_hum_string head)))
end

module Make (S : Abstract.Storage.STORAGE) = struct
  module M = Merkle.Make (S) (Merkle.StringKey)
  module SI = Storage.Make (S)
  module B = Branch.Make (S)

  let root_for tx label =
    let open Utilities.Result in
    let* label = S.get tx (S.Label label) in
    let data = Option.map (fun blob -> Concepts.Blob.bytes_of_blob blob
                                       |> Bytes.to_string
                                       |> Concepts.Hash.of_raw_string)
                 label in
    Ok data

  let persist_root tx label addr =
    let data = Concepts.Hash.blob_of_hash addr in
    S.put tx (S.Label label) data

  class manager storage label head = object (self)
    inherit Lifecycle.null
    inherit Identity.of_id

    val storage : S.connection = storage
    val label : string = label
    val head : M.node Atomic.t = Atomic.make head

    method fetch branch_name =
      SI.with_transaction storage (fun tx ->
          let head = Atomic.get head in
          M.lookup tx branch_name head)

    method protocols = Protocols.[Directory.make self; Registry.make self]

    method list = SI.with_transaction storage (fun tx -> Atomic.get head |> M.keys tx)

    method find key =
      let open Utilities.Result in
      SI.with_transaction storage (fun tx ->
          let* head = Atomic.get head |> M.lookup tx key in
          match head with
          | None -> Ok None
          | Some head -> B.load tx storage head |> Result.map Option.some)

    method update key reference value =
      let open Utilities.Result in
      SI.with_transaction storage (fun tx ->
          match
            Utilities.Atomic.mswap head (fun head ->
                let* branch = M.lookup tx key head |> Result.map_error (fun e -> Some e) in
                (* FIXME: we should have an addressable protocol rather than assuming the hash is the content store address *)
                let reference = Option.map Protocols.Handle.hash reference in
                let value = Option.map Protocols.Handle.hash value in
                if branch = reference then
                  begin
                    let* new_head = match value with
                      | Some value -> M.insert tx key value head
                      | None -> M.remove tx key head
                    in
                    let* _ = persist_root tx label (M.hash_of new_head) in
                    Ok new_head
                  end
                  |> Result.map_error (fun e -> Some e)
                else
                  Error None)
          with
          | Ok _ -> Ok true
          | Error None -> Ok false
          | Error (Some e) -> Error e)

  end

  let make storage label =
    let open Utilities.Result in
    SI.with_transaction storage (fun tx ->
        let* addr = root_for tx label in
        match addr with
        | None ->
           Ok (new manager storage label M.empty |> Protocols.Handle.make)
        | Some addr ->
           let* head = M.find tx addr in
           let* head = Option.to_result ~none:(Error.invalid_root addr) head in
           Ok (new manager storage label head |> Protocols.Handle.make))

end
