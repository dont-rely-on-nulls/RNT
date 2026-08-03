type address = Hash.hash
type t = {name: string; relations: address}

module Field = struct
  let name = "name"
  let relations = "relations"
end

module Error = struct
  open Condition

  let malformed_multigroup () =
    condition "multigroup-malformed"
      "A multigroup representation did not conform to what was expected" empty

  let malformed_hash length =
    condition "multigroup-malformed-hash" "A multigroup relation root was not a valid hash"
      ("length" |=| Value.Integer length)
end

let make ~name ~relations = {name; relations}
let name multigroup = multigroup.name
let relations multigroup = multigroup.relations

module Body = struct
  type nonrec t = t

  let tag = 'm'
  let malformed = Error.malformed_multigroup
  let equal left right = left.name = right.name && Hash.hash_equals left.relations right.relations

  let fields multigroup =
    [ Field.name, Object.Field.string multigroup.name;
      Field.relations, Object.Field.address multigroup.relations ]

  let of_fields data =
    let open Utilities.Result in
    let* name = Object.Field.require_string Field.name data in
    let* relations =
      Object.Field.require_address ~malformed:Error.malformed_hash Field.relations data
    in
    Ok {name; relations}
end

include (Object.Codec.Make (Body) : Object.S with type t := t)
