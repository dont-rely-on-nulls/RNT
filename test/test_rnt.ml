let all_suites =
  Unit.Backend.Storage.suites ()
  @ Unit.Concepts.Cardinality.suites ()
  @ Unit.Kernel.EphemeralRelation.suites ()
  @ Unit.Kernel.Merkle.suites ()
  @ Unit.Kernel.SubstantialRelation.suites ()
  @ Unit.Evaluators.FOL.suites ()
  @ Unit.Evaluators.Lambda.suites ()
  @ Integration.Registration.suites ()

let () = Alcotest.run "RNT" all_suites
