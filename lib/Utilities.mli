module Ordering : sig
  type t = Equal | Smaller | Greater

  val of_int : int -> t
end

module Result : sig
  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  val fmap : ('a -> ('b, 'e) result) -> ('a, 'e) result -> ('b, 'e) result
  val sequence : ('a, 'b) result list -> ('a list, 'b) result
end

module Atomic : sig
  val swap : 'a Atomic.t -> ('a -> 'a) -> 'a Atomic.t
  (* This is silly *)
  val mswap : 'a Atomic.t -> ('a -> ('a, 'b) result) -> ('a Atomic.t, 'b) result
end
