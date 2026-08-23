open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module I = Kernel.Initialization.Make (S)

  let run conn =
    (* let open Utilities.Result in *)
    let _root = I.initialize conn |> Helpers.condition_as_failure in
    ()

  let suite prefix =
    ( "registration/" ^ prefix,
      [test_case "registration tests" `Quick (H.with_connection run "registration-test")])
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
