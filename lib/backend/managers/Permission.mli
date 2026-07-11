type path = Concepts.Path.t
type scope = path
type claim = Read | Write

val claim_name : claim -> string

type claims = claim BatSet.t
type capability
type authority

val root : authority
val grant : authority -> scope -> claims -> capability
val attenuate : capability -> ?scope:scope -> ?claims:claims -> unit -> capability option
val authorizes : capability -> path -> claim -> bool
val scope : capability -> scope
val claims : capability -> claims
