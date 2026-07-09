module AttributeMap = BatMap.String

type t = Value.value AttributeMap.t

val empty: t

val access: string -> t -> Value.value option

val merge: t -> t -> t

val project: BatSet.String.t -> t -> t

val rename: string BatMap.String.t -> t -> t
