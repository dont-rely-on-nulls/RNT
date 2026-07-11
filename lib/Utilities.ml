module Result = struct
  let ( let* ) = Result.bind
  let fmap f m = Result.bind m f
end
