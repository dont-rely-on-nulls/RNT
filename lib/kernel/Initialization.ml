type address = Concepts.Hash.hash
type branch_index_root = address

let fixed_label = "rnt.initialization"
let fixed_label_address = Concepts.Hash.hash_of_bytes (Bytes.of_string fixed_label)

module Error = struct
  open Concepts.Condition

  let malformed_address length =
    condition "initialization-malformed-address"
      "The initialization fixed key does not contain a valid address"
      ("length" |=| Concepts.Value.Integer length)

  let missing_branch_index address =
    condition "initialization-branch-index-missing"
      "The initialization fixed key points at a missing branch index"
      ("address" |=| Concepts.Value.String (Concepts.Hash.to_raw_string address))
end

let address_to_blob address =
  Concepts.Object.Field.address address |> Concepts.Codec.Bencode.to_blob

let address_of_blob blob =
  let open Utilities.Result in
  let* data = Concepts.Codec.Bencode.of_blob blob in
  let* raw = Concepts.Codec.Bencode.as_string data in
  if String.length raw = Concepts.Hash.size then Ok (Concepts.Hash.of_raw_string raw)
  else Error (Error.malformed_address (String.length raw))

module Make (Store : Abstract.Storage.STORAGE) = struct
  module Branch_index = BranchIndex.Make (Store)

  let finish tx = function
    | Ok value ->
        let open Utilities.Result in
        let* () = Store.commit tx in
        Ok value
    | Error condition ->
        let _ = Store.abort tx in
        Error condition

  let with_transaction connection body =
    let open Utilities.Result in
    let* tx = Store.start connection in
    body tx |> finish tx

  let read_in_transaction tx =
    let open Utilities.Result in
    let* fixed = Store.get tx fixed_label_address in
    match fixed with
    | None -> Ok None
    | Some fixed ->
        let* root = address_of_blob fixed in
        let* branch_index = Branch_index.find tx root in
        begin match branch_index with
        | Some _ -> Ok (Some root)
        | None -> Error (Error.missing_branch_index root)
        end

  let store_blob tx blob =
    let open Utilities.Result in
    let address = Concepts.Hash.hash_of_blob blob in
    let* () = Store.put tx address blob in
    Ok address

  let store_fixed_root tx root = Store.put tx fixed_label_address (address_to_blob root)

  let create_initial_branch_state tx =
    let open Utilities.Result in
    (* The first branch state has no synthetic "genesis" commit. Both [current]
       and [history] point at persisted empty trees; the runtime mounts /system
       around those roots after initialization. *)
    let* empty_root = Branch_index.persist tx Branch_index.empty in
    Concepts.BranchState.make ~current:empty_root ~history:empty_root ~tip:None
    |> Concepts.BranchState.to_blob
    |> store_blob tx

  let ensure_default_branch tx root branch_index =
    let open Utilities.Result in
    let* current = Branch_index.find_branch tx BranchIndex.default_branch_name branch_index in
    match current with
    | Some _ -> Ok root
    | None ->
        (* Older initialization slices could leave a valid but empty branch
           index. Repair it by publishing a new root containing master. *)
        let* branch_state = create_initial_branch_state tx in
        let* branch_index =
          Branch_index.put_branch tx BranchIndex.default_branch_name branch_state branch_index
        in
        Ok (Branch_index.hash_of branch_index)

  let create_in_transaction tx =
    let open Utilities.Result in
    let* branch_state = create_initial_branch_state tx in
    let* branch_index =
      Branch_index.put_branch tx BranchIndex.default_branch_name branch_state Branch_index.empty
    in
    let root = Branch_index.hash_of branch_index in
    let* () = store_fixed_root tx root in
    Ok root

  let read connection = with_transaction connection read_in_transaction

  let initialize connection =
    with_transaction connection (fun tx ->
        let open Utilities.Result in
        let* current = read_in_transaction tx in
        match current with
        | None -> create_in_transaction tx
        | Some root ->
            let* branch_index = Branch_index.find tx root in
            begin match branch_index with
            | None -> Error (Error.missing_branch_index root)
            | Some branch_index ->
                let* root' = ensure_default_branch tx root branch_index in
                let* () =
                  if Concepts.Hash.hash_equals root root' then Ok () else store_fixed_root tx root'
                in
                Ok root'
            end )
end
