open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)
  module I = Kernel.Initialization.Make (S)
  module B = Kernel.Branch.Make (S)
  module M = Kernel.Multigroup.Make (S)

  let run conn =
    let open Utilities.Result in
    begin
      let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
      let* multigroup = M.make conn in
      let* branch = B.make conn in
      let* branch' =
        Kernel.Path.(assoc branch ("multigroup" @/ this) "library" (Some multigroup))
      in
      Kernel.Path.(update root ("branch" @/ this) "master" None (Some branch'))
    end
    |> Helpers.condition_as_failure
    |> ignore;
    begin
      let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
      let* _ =
        Kernel.Path.(lookup root ("branch" @/ "master" @/ "multigroup" @/ "library" @/ this))
      in
      let* _ = Kernel.Path.(lookup root ("evaluator" @/ "fol" @/ this)) in
      Ok ()
    end
    |> Helpers.condition_as_failure

  let suite =
    ( "registration",
      [test_case "register-and-lookup" `Quick (H.with_connection run "registration-test")] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite]
