type ordering = Equal | Smaller | Greater

let of_int x = if x < 0 then Smaller else if x > 0 then Greater else Equal
