let all_suites =
  Unit.Backend.Storage.suites ()
  @ Unit.Kernel.SubstantialRelation.suites ()
  @ Integration.Registration.suites ()

let () = Alcotest.run "RNT" all_suites
