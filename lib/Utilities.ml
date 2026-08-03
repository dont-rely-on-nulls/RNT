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
