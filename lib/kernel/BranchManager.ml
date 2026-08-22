module Error = struct
  open Concepts.Condition

  let invalid_root head =
    condition "invalid-root" "The root hash for the database state is missing from the backend. Either your storage is corrupted, or this is a bug in RNT!"
      ("hash" |=| (Concepts.Value.String (Concepts.Hash.to_hum_string head)))

  let no_such_branch branch_name =
    condition "no-such-branch" "A branch with the specified name was not found"
      ("branch"    |=| Concepts.Value.String branch_name)

  let comparison_failed branch_name reference head =
    condition "comparison-failed" "The HEAD of the branch did not match what was expected"
      ("branch"    |=| Concepts.Value.String branch_name &
       "reference" |=| Concepts.Value.String (Concepts.Hash.to_hum_string reference) &
       "head"      |=| Concepts.Value.String (Concepts.Hash.to_hum_string head))
end

module Make (S : Abstract.Storage.STORAGE) = struct
  module M = Merkle.Make (S) (Merkle.StringKey)
  module SI = Storage.Make (S)

  type manager = { storage: S.connection;
                   label : string;
                   head: M.node Atomic.t }

  let root_for tx label =
    let open Utilities.Result in
    let* label = S.get tx (S.Label label) in
    let label = Option.map Concepts.Hash.hash_of_blob label in
    Ok label

  let initialize storage label =
    let open Utilities.Result in
    SI.with_transaction storage (fun tx ->
        let* addr = root_for tx label in
        match addr with
        | None -> failwith "TODO"
        | Some addr ->
           let* head = M.find tx addr in
           let* head = Option.to_result ~none:(Error.invalid_root addr) head in
           Ok { storage; label; head = Atomic.make head })

  let fetch { storage; head; _ } branch_name =
    SI.with_transaction storage (fun tx ->
        let head = Atomic.get head in
        M.lookup tx branch_name head)

  let update { storage; head; label } branch_name reference new_branch =
    let open Utilities.Result in
    let* _ = SI.with_transaction storage (fun tx ->
                 Utilities.Atomic.mswap head (fun head ->
                     let* branch = M.lookup tx branch_name head
                                   |> Result.map (Option.to_result ~none:(Error.no_such_branch branch_name))
                                   |> Result.join in
                     if branch = reference then
                       let* new_head = M.insert tx label new_branch head in
                       Ok new_head
                     else
                       Error (Error.comparison_failed branch_name reference branch))) in
    Ok ()

end
