type address = Hash.hash

type t =
  { name: string;
    target: address }

module Field = struct
  let name = "name"
  let target = "target"
end

module Error = struct
  open Condition

  let malformed_branch () =
    condition "branch-malformed" "A branch representation did not conform to what was expected"
      empty

  let malformed_hash length =
    condition "branch-malformed-hash" "A branch target root was not a valid hash"
      ("length" |=| Value.Integer length)
end

let make ~name ~target = {name; target}

let name branch = branch.name
let target branch = branch.target

module Body = struct
  type nonrec t = t

  let tag = 'b'
  let malformed = Error.malformed_branch

  let equal left right =
    left.name = right.name && Hash.hash_equals left.target right.target

  let fields branch =
    [ Field.name, Object.Field.string branch.name;
      Field.target, Object.Field.address branch.target ]

  let of_fields data =
    let open Utilities.Result in
    let* name = Object.Field.require_string Field.name data in
    let* target = Object.Field.require_address ~malformed:Error.malformed_hash Field.target data in
    Ok {name; target}
end

include (Object.Codec.Make (Body) : Object.S with type t := t)
