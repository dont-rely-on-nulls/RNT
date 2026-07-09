type connection = unit
type transaction = unit

let connect (_: Concepts.Configuration.configuration) = failwith "TODO"

let start (_: connection) = failwith "TODO"
let commit (_: transaction) = failwith "TODO"
let abort (_: transaction) = failwith "TODO"

let get (_: transaction) (_: Concepts.Hash.hash) = failwith "TODO"
let put (_: transaction) (_: Concepts.Hash.hash) (_: Concepts.Representation.blob) = failwith "TODO"
