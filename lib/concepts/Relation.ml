type address = Hash.hash
type schema = string BatMap.String.t

type t =
  { name: string;
    tuples: address;
    schema: schema }

module Field = struct
  let name = "name"
  let tuples = "tuples"
  let schema = "schema"
end

module Error = struct
  open Condition

  let malformed_relation () =
    condition "relation-malformed" "A relation representation did not conform to what was expected"
      empty

  let malformed_hash length =
    condition "relation-malformed-hash" "A relation tuple root was not a valid hash"
      ("length" |=| Value.Integer length)
end

let make ~name ~tuples ~schema = {name; tuples; schema}

let name relation = relation.name
let tuples relation = relation.tuples
let schema relation = relation.schema

let schema_empty = BatMap.String.empty

let schema_of_list fields =
  List.fold_left (fun acc (name, domain) -> BatMap.String.add name domain acc) schema_empty
    fields

let schema_to_list schema = BatMap.String.bindings schema

let schema_to_bencode schema =
  Codec.Bencode.Dict
    (schema_to_list schema
    |> List.map (fun (name, domain) -> name, Codec.Bencode.String domain) )

let schema_of_bencode value =
  let open Utilities.Result in
  let* fields = Codec.Bencode.as_dict value in
  fields
  |> List.map (fun (name, domain) ->
         let* domain = Codec.Bencode.as_string domain in
         Ok (name, domain) )
  |> Utilities.List.sequence
  |> Result.map schema_of_list

module Body = struct
  type nonrec t = t

  let tag = 'r'
  let malformed = Error.malformed_relation

  let equal left right =
    left.name = right.name
    && Hash.hash_equals left.tuples right.tuples
    && BatMap.String.equal String.equal left.schema right.schema

  let fields relation =
    [ Field.name, Object.Field.string relation.name;
      Field.schema, schema_to_bencode relation.schema;
      Field.tuples, Object.Field.address relation.tuples ]

  let of_fields data =
    let open Utilities.Result in
    let* name = Object.Field.require_string Field.name data in
    let* tuples = Object.Field.require_address ~malformed:Error.malformed_hash Field.tuples data in
    let* schema_data = Codec.Bencode.field Field.schema data in
    let* schema = schema_of_bencode schema_data in
    Ok {name; tuples; schema}
end

include (Object.Codec.Make (Body) : Object.S with type t := t)
