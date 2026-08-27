module Error = struct
  open Concepts.Condition

  let invalid_root head =
    condition "invalid-root" "The root hash for the database state is missing from the backend. Either your storage is corrupted, or this is a bug in RNT!"
      ("hash" |=| (Concepts.Value.String (Concepts.Hash.to_hum_string head)))

  let no_such_branch branch_name =
    condition "no-such-branch" "A branch with the specified name was not found"
      ("branch"    |=| Concepts.Value.String branch_name)

  let branch_head_mismatch branch_name reference head =
    condition "branch-head-mismatch" "The HEAD of the branch did not match what was expected"
      ("branch"    |=| Concepts.Value.String branch_name &
       "reference" |=| Concepts.Value.String (Concepts.Hash.to_hum_string reference) &
       "head"      |=| Concepts.Value.String (Concepts.Hash.to_hum_string head))
end

module Make (S : Abstract.Storage.STORAGE) = struct
  module M = Merkle.Make (S) (Merkle.StringKey)
  module SI = Storage.Make (S)
  module B = Branch.Make (S)

  let root_for tx label =
    let open Utilities.Result in
    let* label = S.get tx (S.Label label) in
    let label = Option.map Concepts.Hash.hash_of_blob label in
    Ok label

  let persist_root tx label addr =
    let data = Concepts.Hash.blob_of_hash addr in
    S.put tx (S.Label label) data

  class manager storage label head = object (self)
    inherit Lifecycle.null

    val storage : S.connection = storage
    val label : string = label
    val head : M.node Atomic.t = Atomic.make head

    method fetch branch_name =
      SI.with_transaction storage (fun tx ->
          let head = Atomic.get head in
          M.lookup tx branch_name head)

    method update branch_name reference new_branch =
      let open Utilities.Result in
      SI.with_transaction storage (fun tx ->
          Utilities.Atomic.mswap head (fun head ->
              let* branch = M.lookup tx branch_name head
                            |> fmap (Option.to_result ~none:(Error.no_such_branch branch_name)) in
              if branch = reference then
                let* new_head = M.insert tx label new_branch head in
                let* _ = persist_root tx label (M.hash_of new_head) in
                Ok new_head
              else
                Error (Error.branch_head_mismatch branch_name reference branch)))
      |> Result.map ignore

    method protocols = Protocols.[Directory.make self]

    method list = SI.with_transaction storage (fun tx -> Atomic.get head |> M.keys tx)

    method find key =
      let open Utilities.Result in
      SI.with_transaction storage (fun tx ->
          let* head = Atomic.get head |> M.lookup tx key in
          match head with
          | None -> Ok None
          | Some head -> B.load tx storage key head |> Result.map Option.some)
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
