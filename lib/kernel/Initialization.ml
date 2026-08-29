module Make (S : Abstract.Storage.STORAGE) = struct
  module BM = BranchManager.Make (S)

  let initialize conn =
    let open Utilities.Result in
    let open Protocols in
    let root = Namespace.make () in
    let registry = Registry.from root |> Option.get in
    let* branch = BM.make conn "rnt-head" in
    let* _ = Registry.update registry "branch" None (Some branch) in
    Ok root
end
