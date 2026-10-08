open Alcotest
module K = Rnt.Kernel
module P = Rnt.Protocols
module C = Rnt.Concepts

let ok = Helpers.condition_as_failure
let library = {K.Scope.multigroup= "library"; schema= "default"}
let master = K.Path.("system" @/ "branch" @/ "master" @/ this)
let under a b = K.Path.(of_list (to_list a @ to_list b))
let shelf = K.Scope.path library "shelf"
let s v = C.Value.String v
let title = BatMap.String.singleton "title" {P.Schematics.domain= "string"; provenance= []}

let books titles =
  K.EphemeralRelation.literal title
    (List.map
       (fun t -> {C.Tuple.type_= "book"; attributes= BatMap.String.singleton "title" (s t)})
       titles )

let titles relation = ok (Helpers.titles relation)
let read root path = titles (ok (K.Path.lookup root path))

(* shelf is a stored FOL program reading book where it is stored *)
let shelved =
  K.Source.view ~language:"fol" ~heading:title
    ( Rnt.Evaluators.FOL.(encode (Base (K.Scope.path library "book")))
    |> C.Blob.bytes_of_blob
    |> Bytes.to_string )

let publish root changes = ok (K.Scope.publish root ~branch:"master" ~home:library changes)

let fresh books' =
  let root = ok (Rnt.Scratch.root ()) in
  publish root ["book", Some (books books'); "shelf", Some shelved];
  root

let address handle = P.Addressable.address (Option.get (P.Addressable.from handle))

let reads_as_of_each_state () =
  let root = fresh ["Codd"] in
  publish root ["book", Some (books ["Codd"; "Date"])];
  check (list Helpers.value) "the head's view reads the books as they are"
    [s "Codd"; s "Date"]
    (read root (under master shelf));
  check (list Helpers.value) "the previous state's view reads them as they were"
    [s "Codd"]
    (read root (under master K.Path.("previous" @/ shelf)))

let a_batch_is_one_successor () =
  let root = fresh ["Codd"] in
  let head = ok (K.Path.lookup root master) in
  publish root ["book", Some (books ["Date"]); "loan", Some (books ["Codd"])];
  let next = ok (K.Path.lookup root master) in
  let previous = ok (K.Path.lookup next K.Path.("previous" @/ this)) in
  check bool "two changes, one state after the head" true
    (C.Hash.hash_equals (address previous) (address head));
  let changed =
    ok
      (K.Path.diff
         (ok (K.Path.lookup head K.Path.("multigroup" @/ this)))
         (ok (K.Path.lookup next K.Path.("multigroup" @/ this))) )
  in
  check
    (list (list string))
    "the diff names what changed and nothing else"
    [ ["library"; "schema"; "default"; "relation"; "book"];
      ["library"; "schema"; "default"; "relation"; "loan"] ]
    (List.map K.Path.to_list changed)

let unbinding_removes_a_relation () =
  let root = fresh ["Codd"] in
  publish root ["shelf", None];
  check bool "shelf is gone" true (Result.is_error (K.Path.lookup root (under master shelf)));
  check (list Helpers.value) "book stays"
    [s "Codd"]
    (read root (under master (K.Scope.path library "book")))

let a_scope_reads_names_from_its_home () =
  let root = fresh ["Codd"] in
  K.Scope.publish root ~branch:"master"
    ~home:{K.Scope.multigroup= "store"; schema= "default"}
    ["stock", Some (books ["Date"]); "archive:old", Some (books ["Codd"])]
  |> ok;
  let scope = ok (K.Scope.of_root root ~branch:"master" library) in
  let directory = Option.get (P.Directory.from scope) in
  let found name = ok (P.Directory.find directory name) |> Option.map titles in
  check
    (option (list Helpers.value))
    "a bare name is the home schema's"
    (Some [s "Codd"])
    (found "book");
  check
    (option (list Helpers.value))
    "schema:name stays in the home multigroup"
    (Some [s "Codd"])
    (found "default:book");
  check
    (option (list Helpers.value))
    "multigroup:schema:name leaves it"
    (Some [s "Date"])
    (found "store:default:stock");
  check (option (list Helpers.value)) "what is not there is not found" None (found "stock");
  check
    (option (list Helpers.value))
    "four parts name an attribute, not a relation" None
    (found "library:default:book:title");
  let catalog = ok (K.Scope.catalog (ok (K.Scope.require scope))) in
  check (list string) "the catalog is every relation of the state"
    ["library:default:book"; "library:default:shelf"; "store:archive:old"; "store:default:stock"]
    (List.sort compare catalog);
  check (option string) "a qualified attribute names the relation's own" (Some "title")
    (K.Scope.attribute library "book" "library:default:book:title");
  check (option string) "but not another relation's" None
    (K.Scope.attribute library "book" "shelf:title")

(* A toy language answers a stored relation with its own name, and a run
   with the source it was given. *)
let a_stored_relation_is_viewed_and_a_program_run () =
  let root = fresh ["Codd"] in
  let answer text = Ok (books [text]) in
  let toy =
    K.Source.evaluator ~language:"toy"
      ~view:(fun ~within:_ ~name source -> answer (name ^ " of " ^ source))
      (fun ~within:_ source -> answer source)
  in
  let _ = ok (K.Initialization.mount root "toys") in
  ok (K.Source.register root ~scope:"toys" ~language:"toy" toy);
  publish root ["named", Some (K.Source.view ~language:"toys:toy" ~heading:title "this")];
  check (list Helpers.value) "read from the branch, the view is asked for it by name"
    [s "named of this"]
    (read root (under master (K.Scope.path library "named")));
  check (list Helpers.value) "run, the program is just run"
    [s "that"]
    (titles (ok (K.Source.run root ~language:"toys:toy" ~within:root "that")));
  check bool "an unqualified name is the system's" true
    (Result.is_error (K.Source.run root ~language:"toy" ~within:root "that"))

(* shelf, stored as a denial, says no book may be shelved *)
let a_head_moves_only_to_a_valid_state () =
  let root = fresh [] in
  publish root ["denial:no-books", Some shelved];
  let head = ok (K.Path.lookup root master) in
  let proposed =
    ok
      (K.Path.assoc_all head
         [ ( K.Path.("multigroup" @/ "library" @/ "schema" @/ "default" @/ "relation" @/ this),
             "book",
             Some (books ["Codd"]) ) ] )
  in
  check bool "a state with a book is judged invalid without landing" true
    (Result.is_error (K.Denial.check proposed));
  check bool "publishing it is refused" true
    (Result.is_error
       (K.Scope.publish root ~branch:"master" ~home:library ["book", Some (books ["Codd"])]) );
  check bool "and the head stays" true
    (C.Hash.hash_equals (address head) (address (ok (K.Path.lookup root master))))

let suites () =
  [ ( "kernel/branch",
      [ test_case "reads-as-of-each-state" `Quick reads_as_of_each_state;
        test_case "a-batch-is-one-successor" `Quick a_batch_is_one_successor;
        test_case "unbinding-removes-a-relation" `Quick unbinding_removes_a_relation;
        test_case "a-scope-reads-names-from-its-home" `Quick a_scope_reads_names_from_its_home;
        test_case "a-stored-relation-is-viewed-and-a-program-run" `Quick
          a_stored_relation_is_viewed_and_a_program_run;
        test_case "a-head-moves-only-to-a-valid-state" `Quick a_head_moves_only_to_a_valid_state ] )
  ]
