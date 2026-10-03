open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest
  module H = Helpers.Storage.Make (S) (C)
  module I = Kernel.Initialization.Make (S)
  module B = Kernel.Branch.Make (S)
  module M = Kernel.Multigroup.Make (S)
  module R = Kernel.SubstantialRelation.Make (S)
  module E = Kernel.EphemeralRelation.Make (S)

  let book = Kernel.Path.("multigroup" @/ "library" @/ "relation" @/ "book" @/ this)
  let shelf = Kernel.Path.("multigroup" @/ "library" @/ "relation" @/ "shelf" @/ this)

  let run conn =
    let open Utilities.Result in
    begin
      let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
      let* multigroup = M.make conn in
      let* schematics = H.SI.with_transaction conn (fun tx -> H.store_schema tx ["title"]) in
      let* relation = R.instantiate conn ~schematics in
      let* multigroup =
        Kernel.Path.(assoc multigroup ("relation" @/ this) "book" (Some relation))
      in
      let* view =
        E.persist conn ~name:"shelf" ~evaluator:Evaluators.FOL.name
          ~code:Evaluators.FOL.(encode (Project (Base book, BatFingerTree.singleton "title")))
          (BatMap.String.singleton "title" {Protocols.Schematics.domain= "string"; provenance= []})
      in
      let* multigroup = Kernel.Path.(assoc multigroup ("relation" @/ this) "shelf" (Some view)) in
      let* branch = B.make conn in
      let* branch' =
        Kernel.Path.(assoc branch ("multigroup" @/ this) "library" (Some multigroup))
      in
      Kernel.Path.(update root ("branch" @/ this) "master" None (Some branch'))
    end
    |> Helpers.condition_as_failure
    |> ignore;
    let attributes =
      begin
        let* root = I.initialize ~evaluators:["fol", Evaluators.FOL.make ()] conn in
        let* branch = Kernel.Path.(lookup root ("branch" @/ "master" @/ this)) in
        let* _ = Kernel.Path.lookup branch book in
        let* _ = Kernel.Path.(lookup root ("evaluator" @/ "fol" @/ this)) in
        let* plan = Evaluators.FOL.(instantiate (Kernel.Path.lookup branch) (Base shelf)) in
        let* description = Evaluators.FOL.describe plan in
        Ok (BatMap.String.keys description |> BatList.of_enum)
      end
      |> Helpers.condition_as_failure
    in
    check (list string) "the stored view reads the book it was defined over" ["title"] attributes

  let suite =
    ( "registration",
      [test_case "register-and-lookup" `Quick (H.with_connection run "registration-test")] )
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite]
