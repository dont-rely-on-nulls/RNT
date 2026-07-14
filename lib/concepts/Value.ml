type value
  = String of string
  | Integer of int

let to_string = function
  | String s -> s
  | Integer n -> Int.to_string n

let equal x y =
  match x, y with
  | String x, String y -> x = y
  | Integer x, Integer y -> x = y
  | _, _ -> false
