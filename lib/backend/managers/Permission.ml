type path = Concepts.Path.t
type scope = path
type claim = Read | Write
type claims = claim BatSet.t
type capability = {scope: scope; claims: claims}
type authority = Authority

let root = Authority
let grant Authority scope claims = {scope; claims}
let claim_name : claim -> string = function Read -> "read" | Write -> "write"

let attenuate cap ?scope ?claims () =
  let scope = Option.value scope ~default:cap.scope in
  let claims = Option.value claims ~default:cap.claims in
  if Concepts.Path.is_prefix ~prefix:cap.scope scope && BatSet.subset claims cap.claims then
    Some {scope; claims}
  else None

let authorizes cap path claim =
  Concepts.Path.is_prefix ~prefix:cap.scope path && BatSet.mem claim cap.claims

let scope cap = cap.scope
let claims cap = cap.claims
