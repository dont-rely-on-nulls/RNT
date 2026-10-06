module J = Protocols.Journal
module Bindings = BatMap.String

module Error = struct
  open Concepts.Condition

  let empty_commit () = condition "empty-commit" "A commit has to change at least one name" empty

  let repeated_name name =
    condition "repeated-name" "A commit names the same binding twice"
      ("name" |=| Concepts.Value.String name)
end

(* A snapshot is named by its bindings, so two snapshots binding the
   same objects are the same snapshot. *)
let identity bindings =
  Bindings.fold
    (fun name handle acc ->
      name :: Concepts.Hash.to_raw_string (Protocols.Handle.hash handle) :: acc )
    bindings []
  |> String.concat "\000"
  |> Bytes.of_string
  |> Concepts.Hash.hash_of_bytes

class snapshot bindings =
  object (self)
    inherit Lifecycle.null
    method to_string = "snapshot"
    method hash = identity bindings
    val mutable handle : Protocols.Handle.t option = None
    method protocols : Protocols.Handle.protocol list = [Protocols.Directory.make self]
    method list = Ok (Bindings.keys bindings |> BatFingerTree.of_enum)

    method find name =
      match Bindings.find_opt name bindings with
      | None -> Ok None
      | Some bound -> (
        match Protocols.Derived.from bound, handle with
        | Some derived, Some me -> Protocols.Derived.within derived me |> Result.map Option.some
        | _ -> Ok (Protocols.Handle.copy bound) )

    method attach me = handle <- Some me
  end

let snapshot_of bindings =
  let o = new snapshot bindings in
  let handle = Protocols.Handle.make o in
  o#attach handle; handle

let snapshot bindings = snapshot_of (Bindings.of_list bindings)

type state = {commit: J.commit; bindings: Protocols.Handle.t Bindings.t}

class journal bindings =
  object (self)
    inherit Lifecycle.null
    inherit Identity.of_id
    method to_string = "journal"
    val lock = Mutex.create ()

    (* the latest first *)
    val mutable states =
      [ { commit=
            { J.number= 0;
              snapshot= snapshot_of bindings;
              changed= Bindings.keys bindings |> BatList.of_enum };
          bindings } ]

    val mutable guards : (string * J.guard) list = []
    val mutable observers : (string * J.observer) list = []

    method protocols : Protocols.Handle.protocol list =
      Protocols.[Directory.make self; Registry.make self; J.make self]

    method head = (List.hd states).commit
    method history = List.rev_map (fun {commit; _} -> commit) states

    method guard name g =
      Mutex.protect lock (fun () ->
          guards <-
            List.remove_assoc name guards @ Option.fold ~none:[] ~some:(fun g -> [name, g]) g )

    method observe name f =
      Mutex.protect lock (fun () ->
          observers <-
            List.remove_assoc name observers @ Option.fold ~none:[] ~some:(fun f -> [name, f]) f )

    method list = Ok (Bindings.keys (List.hd states).bindings |> BatFingerTree.of_enum)

    method find name =
      Ok
        ( Bindings.find_opt name (List.hd states).bindings
        |> Utilities.Option.fmap Protocols.Handle.copy )

    method update name expected replacement =
      self#commit [{J.name; expected; replacement}] |> Result.map Option.is_some

    (* Guards run in the order they were installed, and observers after
       the commit has landed, both while holding the journal, so they
       see commits one at a time and in order. *)
    method commit (changes : J.change list) =
      let open Utilities.Result in
      let names = List.map (fun (c : J.change) -> c.name) changes in
      let repeated =
        List.find_opt (fun n -> List.length (List.filter (String.equal n) names) > 1) names
      in
      match changes, repeated with
      | [], _ -> Error (Error.empty_commit ())
      | _, Some name -> Error (Error.repeated_name name)
      | _ ->
          Mutex.protect lock (fun () ->
              let current = List.hd states in
              let expected (c : J.change) =
                Bindings.find_opt c.name current.bindings = c.expected
              in
              if not (List.for_all expected changes) then Ok None
              else
                let bindings =
                  List.fold_left
                    (fun bindings (c : J.change) ->
                      match c.replacement with
                      | Some h -> Bindings.add c.name h bindings
                      | None -> Bindings.remove c.name bindings )
                    current.bindings changes
                in
                let commit =
                  { J.number= current.commit.number + 1;
                    snapshot= snapshot_of bindings;
                    changed= names }
                in
                let proposal = {J.previous= current.commit; proposed= commit} in
                let* () =
                  List.fold_left
                    (fun acc (_, g) ->
                      let* () = acc in
                      g proposal )
                    (Ok ()) guards
                in
                states <- {commit; bindings} :: states;
                List.iter (fun (_, f) -> f commit) observers;
                Ok (Some commit) )
  end

let make ?(bindings = []) () = Protocols.Handle.make (new journal (Bindings.of_list bindings))

let adopt directory =
  let open Utilities.Result in
  let* listing = Protocols.Handle.require Protocols.Directory.from directory in
  let* names = Protocols.Directory.list listing in
  let* bindings =
    BatFingerTree.to_list names
    |> List.map (fun name ->
        let* found = Protocols.Directory.find listing name in
        Ok (Option.map (fun h -> name, h) found) )
    |> Utilities.List.sequence
  in
  Ok (make ~bindings:(List.filter_map Fun.id bindings) ())

(* What a name is bound to is read as a copy, which has to stay valid
   until the swap has compared against it. *)
let rebind directory bindings =
  let open Utilities.Result in
  let* listing = Protocols.Handle.require Protocols.Directory.from directory in
  let holding names f =
    let* found =
      List.map (fun name -> Protocols.Directory.find listing name) names |> Utilities.List.sequence
    in
    Fun.protect
      ~finally:(fun () -> List.iter (Option.iter Protocols.Handle.release) found)
      (fun () -> f found)
  in
  let rec together journal =
    let* landed =
      holding (List.map fst bindings) (fun found ->
          List.map2
            (fun (name, replacement) expected -> {J.name; expected; replacement})
            bindings found
          |> J.commit journal )
    in
    match landed with Some _ -> Ok () | None -> together journal
  in
  let rec one registry name replacement =
    let* swapped =
      holding [name] (fun found ->
          Protocols.Registry.update registry name (List.hd found) replacement )
    in
    if swapped then Ok () else one registry name replacement
  in
  match J.from directory, bindings with
  | _, [] -> Ok ()
  | Some journal, _ -> together journal
  | None, _ ->
      let* registry = Protocols.Handle.require Protocols.Registry.from directory in
      List.fold_left
        (fun acc (name, replacement) ->
          let* () = acc in
          one registry name replacement )
        (Ok ()) bindings
