module Result = struct
  let ( let* ) = Result.bind
  let fmap f m = Result.bind m f

  let sequence ms = List.fold_right
                      (fun m acc ->
                        let* acc = acc in
                        let* m = m in
                        Ok (m::acc))
                      ms
                      (Ok [])
end

module Atomic = struct
  let rec swap atom f =
    let v = Atomic.get atom in
    let v' = f v in
    if Atomic.compare_and_set atom v v'
    then atom
    else swap atom f

  let rec mswap atom f =
    let open Result in
    let v = Atomic.get atom in
    let* v' = f v in
    if Atomic.compare_and_set atom v v'
    then Ok atom
    else mswap atom f
end
