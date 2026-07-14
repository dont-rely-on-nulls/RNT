module Result : sig
  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  val fmap : ('a -> ('b, 'e) result) -> ('a, 'e) result -> ('b, 'e) result
end

module Map : sig
  val indexed : 'a array -> ('a, int) BatMap.t
  val flip : ('a, 'b) BatMap.t -> ('b, 'a) BatMap.t
end

val enumeration : 'a array -> ('a -> int) * (int -> 'a)
