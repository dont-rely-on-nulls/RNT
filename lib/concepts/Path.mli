type t = string BatFingerTree.t

val empty : t
val of_list : string list -> t
val to_list : t -> string list
val snoc : t -> string -> t
val to_string : t -> string
val is_prefix : prefix:t -> t -> bool
