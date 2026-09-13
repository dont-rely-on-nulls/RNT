let all_suites =
  Unit.Backend.Storage.suites ()
  @ Unit.Kernel.Merkle.suites ()
  @ Unit.Kernel.SubstantialRelation.suites ()
  @ Unit.Evaluators.FOL.suites ()
  @ Integration.Registration.suites ()

let () = Alcotest.run "RNT" all_suites
