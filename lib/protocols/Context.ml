type t =
  { snapshot : Concepts.Hash.hash
  ; root : Handle.t
  ; status : unit -> [`Live | `Cancelled | `Exhausted] }
