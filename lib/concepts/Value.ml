type value = String of string | Integer of int

let to_string = function String s -> s | Integer n -> Int.to_string n
