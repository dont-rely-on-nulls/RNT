module BranchValue = Merkle.StringKey (* FIXME *)

type branch = string

module Error = struct
  open Concepts.Condition

  let invalid_root head = condition "invalid-root" "The root hash for the database state is missing from the backend. Either your storage is corrupted, or this is a bug in RNT!"
                            ("hash" |=| (Concepts.Value.String (Concepts.Hash.to_hum_string head)))
end

module Make (S : Abstract.Storage.STORAGE) = struct
  module I = Merkle.Interface (S) (Merkle.StringKey) (BranchValue)
  module SI = Storage.Make (S)

  type manager = { storage: S.connection;
                   label : string;
                   head: I.node Atomic.t }

  let root_for tx label =
    let open Utilities.Result in
    let* label = S.get tx (S.Label label) in
    let label = Option.map Concepts.Hash.hash_of_blob label in
    Ok label

  let persist_root tx label new_branch = failwith "TODO"

  let initialize storage label =
    let open Utilities.Result in
    SI.with_transaction storage (fun tx ->
        let* addr = root_for tx label in
        match addr with
        | None -> failwith "TODO"
        | Some addr ->
           let* head = I.find tx addr in
           let* head = Option.to_result ~none:(Error.invalid_root addr) head in
           Ok { storage; label; head = Atomic.make head })

  let fetch { storage; head; _ } branch_name =
    SI.with_transaction storage (fun tx ->
        let head = Atomic.get head in
        I.lookup tx branch_name head)

  let update ({ storage; head; label } as manager) branch_name f =
    let open Utilities.Result in
    let* _ = SI.with_transaction storage (fun tx ->
                 Utilities.Atomic.mswap head (fun head ->
                     let* branch = I.lookup tx branch_name head in
                     let new_branch = f branch in
                     let* () = persist_root tx label new_branch in
                     new_branch)) in
    Ok ()
end
