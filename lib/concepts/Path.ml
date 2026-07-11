type t = string BatFingerTree.t

let empty : t = BatFingerTree.empty

let of_list (components : string list) : t = BatFingerTree.of_list components

let to_list (path : t) : string list = BatFingerTree.to_list path

let snoc (path : t) (component : string) : t = BatFingerTree.snoc path component

let to_string (path : t) : string = String.concat "/" (to_list path)

let is_prefix ~(prefix : t) (path : t) : bool =
  let rec walk prefix path =
    match prefix, path with
    | [], _ -> true
    | p :: prefix, x :: path -> p = x && walk prefix path
    | _ :: _, [] -> false
  in
  walk (to_list prefix) (to_list path)
