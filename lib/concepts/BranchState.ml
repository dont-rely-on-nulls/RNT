type address = Hash.hash

type t =
  { current: address;
    history: address;
    tip: address option }

module Field = struct
  let current = "current"
  let history = "history"
  let tip = "tip"
end

module Error = struct
  open Condition

  let malformed_branch_state () =
    condition "branch-state-malformed"
      "A branch state representation did not conform to what was expected" empty

  let malformed_hash length =
    condition "branch-state-malformed-hash" "A branch state address was not a valid hash"
      ("length" |=| Value.Integer length)
end

let make ~current ~history ~tip = {current; history; tip}

let current branch_state = branch_state.current
let history branch_state = branch_state.history
let tip branch_state = branch_state.tip

let address_bencode address = Object.Field.address address

let address_option_bencode = function
  | None -> Codec.Bencode.List []
  | Some address -> Codec.Bencode.List [address_bencode address]

let require_address_bencode = function
  | Codec.Bencode.String raw ->
      if String.length raw = Hash.size then Ok (Hash.of_raw_string raw)
      else Error (Error.malformed_hash (String.length raw))
  | _ -> Error (Error.malformed_branch_state ())

let require_address_option key data =
  let open Utilities.Result in
  let* value = Codec.Bencode.field key data in
  let* entries = Codec.Bencode.as_list value in
  match entries with
  | [] -> Ok None
  | [value] ->
      let* address = require_address_bencode value in
      Ok (Some address)
  | _ -> Error (Error.malformed_branch_state ())

let equal_address_option left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> Hash.hash_equals left right
  | _ -> false

module Body = struct
  type nonrec t = t

  let tag = 's'
  let malformed = Error.malformed_branch_state

  let equal left right =
    Hash.hash_equals left.current right.current
    && Hash.hash_equals left.history right.history
    && equal_address_option left.tip right.tip

  let fields branch_state =
    [ Field.current, address_bencode branch_state.current;
      Field.history, address_bencode branch_state.history;
      Field.tip, address_option_bencode branch_state.tip ]

  let of_fields data =
    let open Utilities.Result in
    let* current =
      Object.Field.require_address ~malformed:Error.malformed_hash Field.current data
    in
    let* history =
      Object.Field.require_address ~malformed:Error.malformed_hash Field.history data
    in
    let* tip = require_address_option Field.tip data in
    Ok {current; history; tip}
end

include (Object.Codec.Make (Body) : Object.S with type t := t)
