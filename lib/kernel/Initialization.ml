module Make (S : Abstract.Storage.STORAGE) = struct
  module BM = BranchManager.Make (S)

  let initialize ?(evaluators = []) conn =
    let open Utilities.Result in
    let open Protocols in
    let root = Namespace.make () in
    let registry = Registry.from root |> Option.get in
    let* branch_manager = BM.make conn "rnt-head" in
    let* _ = Registry.update registry "branch" None (Some branch_manager) in
    let evaluator_namespace = Namespace.make () in
    let evaluator_registry = Registry.from evaluator_namespace |> Option.get in
    let* _ =
      List.fold_left
        (fun acc (name, handle) ->
          let* _ = acc in
          Registry.update evaluator_registry name None (Some handle))
        (Ok true) evaluators
    in
    let* _ = Registry.update registry "evaluator" None (Some evaluator_namespace) in
    Ok root
end
