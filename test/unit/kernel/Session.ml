open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)
  module I = Rnt.Kernel.Initialization.Make (S)
  module B = Rnt.Kernel.Branch.Make (S)
  module M = Rnt.Kernel.Multigroup.Make (S)
  module Session = Rnt.Kernel.Session.Make (S)

  let address handle =
    let open Utilities.Result in
    let* addressable = Protocols.Handle.require Protocols.Addressable.from handle in
    Ok (Protocols.Addressable.address addressable)

  let finds root path = Rnt.Kernel.Path.lookup root path |> Result.is_ok

  let pin_and_follow conn =
    let before, after, unchanged, followed, pinned, refused =
      begin
        let open Utilities.Result in
        let open Rnt.Kernel.Path in
        let* root = I.initialize conn in
        let* branch = B.make conn in
        let* _ = update root ("branch" @/ this) "master" None (Some branch) in
        let* tip = address branch in
        let session = Session.make conn {Protocols.Session.branch= "master"; snapshot= tip} in
        let* _ = update root ("session" @/ this) "client" None (Some session) in
        let library = "session" @/ "client" @/ "branch" @/ "multigroup" @/ "library" @/ this in
        let before = finds root library in
        let* multigroup = M.make conn in
        let* branch' = assoc branch ("multigroup" @/ this) "library" (Some multigroup) in
        let* _ = update root ("branch" @/ this) "master" (Some branch) (Some branch') in
        let unchanged = finds root library in
        let* tip' = address branch' in
        let* interface = Protocols.Handle.require Protocols.Session.from session in
        Protocols.Session.pin interface {Protocols.Session.branch= "master"; snapshot= tip'};
        let after = finds root library in
        let followed = Protocols.Session.state interface in
        let* pinned = lookup root ("session" @/ "client" @/ "branch" @/ this) |> fmap address in
        let refused =
          assoc session ("branch" @/ "multigroup" @/ this) "other" (Some multigroup)
          |> Result.is_error
        in
        Ok (before, after, unchanged, followed, Concepts.Hash.hash_equals pinned tip', refused)
      end
      |> Helpers.condition_as_failure
    in
    check bool "the pinned state lacks the multigroup" false before;
    check bool "advancing the branch leaves the session pinned" false unchanged;
    check bool "re-pinning exposes the multigroup" true after;
    check string "the session follows its branch" "master" followed.Protocols.Session.branch;
    check bool "the session reconstructs the pinned branch" true pinned;
    check bool "the session refuses derivation through it" true refused

  let single_handle conn =
    let refused, reacquired =
      begin
        let open Utilities.Result in
        let open Rnt.Kernel.Path in
        let* root = I.initialize conn in
        let* branch = B.make conn in
        let* tip = address branch in
        let session = Session.make conn {Protocols.Session.branch= "master"; snapshot= tip} in
        let* _ = update root ("session" @/ this) "client" None (Some session) in
        let client = "session" @/ "client" @/ this in
        let* _ = lookup root ("session" @/ "client" @/ "branch" @/ this) in
        let* held = lookup root client in
        let refused = finds root client in
        Protocols.Handle.release held;
        Ok (refused, finds root client)
      end
      |> Helpers.condition_as_failure
    in
    check bool "a second handle to the session is refused" false refused;
    check bool "releasing the handle frees the session" true reacquired

  let suite =
    ( "kernel/session",
      [ test_case "pin-and-follow" `Quick (H.with_connection pin_and_follow "session-test");
        test_case "single-handle" `Quick (H.with_connection single_handle "session-single-test") ] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite]
