type address = Concepts.Hash.hash

type t =
  { default_branch: string;
    branches: address }

let fixed_label = "rnt.boot"
let fixed_label_address = Concepts.Hash.hash_of_bytes (Bytes.of_string fixed_label)

module Field = struct
  let default_branch = "default_branch"
  let branches = "branches"
end

module Error = struct
  open Concepts.Condition

  let malformed_initialization () =
    condition "initialization-malformed"
      "An initialization representation did not conform to what was expected" empty

  let malformed_hash length =
    condition "initialization-malformed-hash"
      "An initialization address was not a valid hash"
      ("length" |=| Concepts.Value.Integer length)

  let missing_target address =
    condition "initialization-target-missing"
      "The fixed initialization label points at a missing object"
      ("address" |=| Concepts.Value.String (Concepts.Hash.to_raw_string address))
end

let make ~default_branch ~branches = {default_branch; branches}

let default_branch initialization = initialization.default_branch
let branches initialization = initialization.branches

module Body = struct
  type nonrec t = t

  let tag = 'i'
  let malformed = Error.malformed_initialization

  let equal left right =
    String.equal left.default_branch right.default_branch
    && Concepts.Hash.hash_equals left.branches right.branches

  let fields initialization =
    [ Field.default_branch, Concepts.Object.Field.string initialization.default_branch;
      Field.branches, Concepts.Object.Field.address initialization.branches ]

  let of_fields data =
    let open Utilities.Result in
    let* default_branch =
      Concepts.Object.Field.require_string Field.default_branch data
    in
    let* branches =
      Concepts.Object.Field.require_address ~malformed:Error.malformed_hash Field.branches data
    in
    Ok {default_branch; branches}
end

include (Concepts.Object.Codec.Make (Body) : Concepts.Object.S with type t := t)

let address initialization = to_blob initialization |> Concepts.Hash.hash_of_blob

let address_to_blob address =
  Concepts.Object.Field.address address |> Concepts.Codec.Bencode.to_blob

let address_of_blob blob =
  let open Utilities.Result in
  let* data = Concepts.Codec.Bencode.of_blob blob in
  let* raw = Concepts.Codec.Bencode.as_string data in
  if String.length raw = Concepts.Hash.size then Ok (Concepts.Hash.of_raw_string raw)
  else Error (Error.malformed_hash (String.length raw))

module Make (Store : Abstract.Storage.STORAGE) = struct
  let register tx initialization =
    let open Utilities.Result in
    let blob = to_blob initialization in
    let initialization_address = Concepts.Hash.hash_of_blob blob in
    let* () = Store.put tx initialization_address blob in
    let* () = Store.put tx fixed_label_address (address_to_blob initialization_address) in
    Ok initialization_address

  let load tx =
    let open Utilities.Result in
    let* label = Store.get tx fixed_label_address in
    match label with
    | None -> Ok None
    | Some label ->
        let* initialization_address = address_of_blob label in
        let* initialization = Store.get tx initialization_address in
        begin match initialization with
        | None -> Error (Error.missing_target initialization_address)
        | Some initialization ->
            let* initialization = of_blob initialization in
            Ok (Some initialization)
        end
end
