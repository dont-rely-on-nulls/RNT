module Result = struct
  let ( let* ) = Result.bind
  let fmap f m = Result.bind m f
end

module type SEQUENCE = sig
  type 'a t

  val empty : 'a t
  val cons : 'a -> 'a t -> 'a t
  val fold : ('a -> 'b -> 'b) -> 'a t -> 'b -> 'b
end

module Generic (S : SEQUENCE) = struct
  let sequence ms =
    let open Result in
    S.fold
      (fun m acc ->
        let* acc = acc in
        let* m = m in
        Ok (S.cons m acc))
      ms
      (Ok S.empty)
end

module List = struct
  module ListSequence : SEQUENCE with type 'a t = 'a list = struct
    type 'a t = 'a list

    let empty = []
    let cons x xs = x::xs
    let fold = List.fold_right
  end

  include Generic (ListSequence)
end

module FingerTree = struct
  module FingerTreeSequence : SEQUENCE with type 'a t = 'a BatFingerTree.t = struct
    type 'a t = 'a BatFingerTree.t

    let empty = BatFingerTree.empty
    let cons x xs = BatFingerTree.cons xs x
    let fold f xs acc = BatFingerTree.fold_right
                          (Fun.flip f)
                          acc
                          xs
  end

  include Generic (FingerTreeSequence)

  let map2 f xs ys =
    let rec frob xs ys acc =
      match BatFingerTree.front xs with
      | None -> acc
      | Some (xs', x) ->
         match BatFingerTree.front ys with
         | None -> acc
         | Some (ys', y) ->
            f x y
            |> BatFingerTree.snoc acc
            |> frob xs' ys'
    in
    frob xs ys BatFingerTree.empty

  let zip xs ys = map2 (fun x y -> x, y) xs ys
end
