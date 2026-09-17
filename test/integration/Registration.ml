open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module I = Kernel.Initialization.Make (S)
  module B = Kernel.Branch.Make (S)

  let run conn =
    let open Utilities.Result in
    begin
      let* root = I.initialize conn in
      let* branch = B.make conn in
      Kernel.Path.(update root ("branch" @/ this) "master" None (Some branch))
    end
    |> Helpers.condition_as_failure |> ignore;
    begin
      let* root = I.initialize conn in
      Kernel.Path.(lookup root ("branch" @/ "master" @/ "multigroup" @/ this))
    end
    |> Helpers.condition_as_failure |> ignore

  let suite prefix =
    ( "registration/" ^ prefix,
      [test_case "registration tests" `Quick (H.with_connection run "registration-test")])
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
