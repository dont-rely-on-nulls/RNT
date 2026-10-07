module Error = struct
  open Concepts.Condition

  let taken name =
    condition "name-taken" "A namespace already binds the name"
      ("name" |=| Concepts.Value.String name)
end

module Make (S : Abstract.Storage.STORAGE) = struct
  module BM = BranchManager.Make (S)

  let bind namespace (name, handle) =
    let open Utilities.Result in
    let* registry = Protocols.Handle.require Protocols.Registry.from namespace in
    let* bound = Protocols.Registry.update registry name None (Some handle) in
    if bound then Ok () else Error (Error.taken name)

  let namespace entries =
    let open Utilities.Result in
    let n = Namespace.make () in
    let* () =
      List.fold_left
        (fun acc entry ->
          let* () = acc in
          bind n entry )
        (Ok ()) entries
    in
    Ok n

  (* \system keeps the head label it had before subsystems got roots of
     their own, so a database made then still opens. *)
  let initialize ?(evaluators = []) conn =
    let open Utilities.Result in
    let* evaluator = namespace evaluators in
    let* branch = BM.make ~evaluators:evaluator conn "rnt-head" in
    let* system =
      namespace
        [ "branch", branch;
          "evaluator", evaluator;
          "session", Namespace.make ();
          "application", Namespace.make () ]
    in
    namespace ["system", system]

  let mount conn root name =
    let open Utilities.Result in
    let* evaluators = Path.lookup root Source.evaluators in
    let* branch = BM.make ~evaluators conn (name ^ "-head") in
    let* subsystem = namespace ["branch", branch] in
    let* () = bind root (name, subsystem) in
    Ok subsystem
end
