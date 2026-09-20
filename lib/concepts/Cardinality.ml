type t = Empty | Bounded of int | Finite | Countable

let bounded n = if n <= 0 then Empty else Bounded n
let rank = function Empty -> 0 | Bounded _ -> 1 | Finite -> 2 | Countable -> 3

let compare a b =
  match a, b with
  | Bounded n, Bounded m -> Utilities.Ordering.of_int (Int.compare n m)
  | _ -> Utilities.Ordering.of_int (Int.compare (rank a) (rank b))

let equal a b = compare a b = Utilities.Ordering.Equal
let leq a b = compare a b <> Utilities.Ordering.Greater
let join a b = if leq a b then b else a
let meet a b = if leq a b then a else b

let product a b =
  match a, b with
  | Empty, _ | _, Empty -> Empty
  | Countable, _ | _, Countable -> Countable
  | Finite, _ | _, Finite -> Finite
  | Bounded n, Bounded m -> if n > max_int / m then Finite else bounded (n * m)

let exhaustible = function Countable -> false | Empty | Bounded _ | Finite -> true

let to_string = function
  | Empty -> "empty"
  | Bounded n -> Printf.sprintf "bounded(%d)" n
  | Finite -> "finite"
  | Countable -> "countable"
