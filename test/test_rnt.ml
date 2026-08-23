let all_suites =
  Unit.Backend.Storage.suites ()
  @ Integration.Registration.suites ()

let () = Alcotest.run "RNT" all_suites
