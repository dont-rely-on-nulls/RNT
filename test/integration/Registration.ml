open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module I = Kernel.Initialization.Make (S)
  module B = Kernel.Branch.Make (S)

  module Error = struct
    open Concepts.Condition

    let not_found () = condition "not-found" "An expected object was not present" empty
  end

  let run conn =
    let open Utilities.Result in
    let open Protocols in
    let registration =
      begin
        let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
        let* bm = Kernel.Path.(lookup root ("branch" @/ this))
                  |> fmap (Option.to_result ~none:(Error.not_found ())) in
        let* bm = Registry.from bm |> Option.to_result ~none:(Error.not_found ()) in
        let* branch = B.make conn in
        Registry.update bm "master" None (Some branch)
      end
      |> Helpers.condition_as_failure in
    let presence =
      begin
        let* root = I.initialize conn in
        let* bm = Kernel.Path.(lookup root ("branch" @/ this))
                  |> fmap (Option.to_result ~none:(Error.not_found ())) in
        let* bm = Directory.from bm |> Option.to_result ~none:(Error.not_found ()) in
        Directory.find bm "master" |> Result.map Option.is_some
      end
      |> Helpers.condition_as_failure in
    let evaluator =
      begin
        let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
        Kernel.Path.(lookup root ("evaluator" @/ "fol" @/ this)) |> Result.map Option.is_some
      end
      |> Helpers.condition_as_failure in
    check bool "" true registration;
    check bool "" true presence;
    check bool "the fol evaluator is registered" true evaluator

  let suite prefix =
    ( "registration/" ^ prefix,
      [test_case "registration tests" `Quick (H.with_connection run "registration-test")])
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
