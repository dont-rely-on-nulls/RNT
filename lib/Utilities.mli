module Result : sig
  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  val fmap : ('a -> ('b, 'e) result) -> ('a, 'e) result -> ('b, 'e) result
  val sequence : ('a, 'b) result list -> ('a list, 'b) result
end
