module Result = struct
  let ( let* ) = Result.bind
  let fmap f m = Result.bind m f
end

module Map = struct
  let indexed arr =
    Array.to_seq arr
    |> BatSeq.mapi (fun i x -> i, x)
    |> BatMap.of_seq

  let flip m =
    BatMap.to_seq m
    |> BatSeq.map (fun (a, b) -> b, a)
    |> BatMap.of_seq
end

let enumeration xs =
  let to_repr = Map.indexed xs in
  let from_repr = Map.flip to_repr in
  (fun x -> BatMap.find x to_repr),
  (fun i -> BatMap.find i from_repr)
