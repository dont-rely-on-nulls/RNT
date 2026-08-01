module Result : sig
  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  val fmap : ('a -> ('b, 'e) result) -> ('a, 'e) result -> ('b, 'e) result
end

module List : sig
  val sequence : ('a, 'b) result list -> ('a list, 'b) result
end

module FingerTree : sig
  val map2 : ('a -> 'b -> 'c) -> 'a BatFingerTree.t -> 'b BatFingerTree.t -> 'c BatFingerTree.t
  val zip : 'a BatFingerTree.t -> 'b BatFingerTree.t -> ('a * 'b) BatFingerTree.t

  val sequence : ('a, 'b) result BatFingerTree.t -> ('a BatFingerTree.t, 'b) result
end
