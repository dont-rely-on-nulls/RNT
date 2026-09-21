module Error = struct
  open Concepts.Condition

  let unbound_variable name =
    condition "unbound-variable" "A comparison mentioned a variable that nothing has bound"
      ("variable" |=| Concepts.Value.String name)

  let absent_attribute target attribute =
    condition "absent-attribute"
      "A membership named an attribute that the tuples of its target do not carry"
      ( "target" |=| Concepts.Value.String (Kernel.Path.to_string target)
      & "attribute" |=| Concepts.Value.String attribute )

  let open_constraint name variables =
    condition "open-constraint"
      "A constraint is asserted of every state and so must be closed, and this one leaves \
       variables that nothing covers"
      ( "constraint" |=| Concepts.Value.String name
      & "variables" |=| Concepts.Value.String (String.concat ", " variables) )

  let violated name =
    condition "constraint-violated"
      "A candidate state was refused because the violations of a constraint imposed on it are not \
       empty"
      ("constraint" |=| Concepts.Value.String name)
end

type binding_expr = Var of string | Const of Concepts.Value.value
type membership = {target: Kernel.Path.t; binding: binding_expr BatMap.String.t}

type formula =
  | Exists of comprehension
  | Not of formula
  | And of formula * formula
  | Or of formula * formula
  | Eq of {left: binding_expr; right: binding_expr}
  | Truth of bool

and comprehension = {quantifiers: membership list; body: formula}

type scope = Protocols.Handle.t

let variables_of quantifiers =
  List.fold_left
    (fun acc {binding; _} ->
      BatMap.String.values binding
      |> BatEnum.fold
           (fun acc -> function Var name -> BatSet.String.add name acc | Const _ -> acc)
           acc )
    BatSet.String.empty quantifiers

let rec free = function
  | Truth _ -> BatSet.String.empty
  | Not formula -> free formula
  | And (left, right) | Or (left, right) -> BatSet.String.union (free left) (free right)
  | Eq {left; right} ->
      let mentioned = function
        | Var name -> BatSet.String.singleton name
        | Const _ -> BatSet.String.empty
      in
      BatSet.String.union (mentioned left) (mentioned right)
  | Exists {quantifiers; body} -> BatSet.String.diff (free body) (variables_of quantifiers)

let attributes_of ({quantifiers; _} as comprehension) =
  BatSet.String.union (variables_of quantifiers) (free (Exists comprehension))

(* Both takes nested negation; SQL also gets it from outer joins, which this form lacks. *)
type polarity = Positive | Negative | Both

let merged existing polarity =
  match existing, polarity with
  | Positive, Positive -> Positive
  | Negative, Negative -> Negative
  | _ -> Both

let at target (candidate, _) = Kernel.Path.equal candidate target

let relevance formula =
  let flipped = function Positive -> Negative | Negative -> Positive | Both -> Both in
  let record polarity occurrences {target; _} =
    let polarity =
      match List.find_opt (at target) occurrences with
      | None -> polarity
      | Some (_, existing) -> merged existing polarity
    in
    (target, polarity) :: List.filter (Fun.negate (at target)) occurrences
  in
  let rec walk polarity occurrences = function
    | Truth _ | Eq _ -> occurrences
    | Not formula -> walk (flipped polarity) occurrences formula
    | And (left, right) | Or (left, right) -> walk polarity (walk polarity occurrences left) right
    | Exists {quantifiers; body} ->
        walk polarity (List.fold_left (record polarity) occurrences quantifiers) body
  in
  walk Positive [] formula

type environment = Concepts.Value.value BatMap.String.t

(* Cursors a walk holds open are suspended inside it when a caller
   abandons the walk, so they are tracked to be closed on release. *)
module Live = struct
  let none () = ref []
  let opened live handle = live := handle :: !live

  let closed live handle =
    if List.memq handle !live then begin
      live := List.filter (( != ) handle) !live;
      Protocols.Handle.release handle
    end

  let abandoned live =
    List.iter Protocols.Handle.release !live;
    live := []
end

let resolve scope target = Kernel.Path.lookup scope target

let value_of environment = function
  | Const value -> Ok value
  | Var name ->
      BatMap.String.find_opt name environment
      |> Option.to_result ~none:(Error.unbound_variable name)

let fixed environment = function
  | Const value -> Some value
  | Var name -> BatMap.String.find_opt name environment

let pushed environment binding =
  BatMap.String.enum binding
  |> BatEnum.fold
       (fun pushed (attribute, expression) ->
         match fixed environment expression with
         | Some value -> BatMap.String.add attribute value pushed
         | None -> pushed )
       Protocols.Generative.nothing

let agreeing environment expression value =
  match expression, fixed environment expression with
  | _, Some held -> if Concepts.Value.equal held value then Some environment else None
  | Var name, None -> Some (BatMap.String.add name value environment)
  | Const _, None -> None

let extend target binding environment tuple =
  let open Utilities.Result in
  BatMap.String.enum binding
  |> BatEnum.fold
       (fun acc (attribute, expression) ->
         let* acc = acc in
         match acc with
         | None -> Ok None
         | Some environment -> (
           match BatMap.String.find_opt attribute tuple.Concepts.Tuple.attributes with
           | None -> Error (Error.absent_attribute target attribute)
           | Some value -> Ok (agreeing environment expression value) ) )
       (Ok (Some environment))

type step = Continue | Stop

let rec holds ~live scope environment formula =
  let open Utilities.Result in
  match formula with
  | Truth truth -> Ok truth
  | Not formula -> holds ~live scope environment formula |> Result.map not
  | And (left, right) ->
      let* left = holds ~live scope environment left in
      if left then holds ~live scope environment right else Ok false
  | Or (left, right) ->
      let* left = holds ~live scope environment left in
      if left then Ok true else holds ~live scope environment right
  | Eq {left; right} ->
      let* left = value_of environment left in
      let* right = value_of environment right in
      Ok (Concepts.Value.equal left right)
  | Exists comprehension ->
      let* step = assignments ~live scope environment comprehension ~visit:(fun _ -> Stop) in
      Ok (step = Stop)

(* An assignment reached through several tuples is still one
   assignment, which the walk settles rather than its callers, since a
   relation built over it has to be a set. *)
and assignments ~live scope environment {quantifiers; body} ~visit =
  let open Utilities.Result in
  let fingerprint environment =
    Concepts.Tuple.hash {Concepts.Tuple.type_= ""; attributes= environment}
    |> Concepts.Hash.to_raw_string
  in
  let rec walk seen environment = function
    | [] -> (
        let* satisfied = holds ~live scope environment body in
        let taken = fingerprint environment in
        match satisfied, BatSet.String.mem taken seen with
        | false, _ | true, true -> Ok (seen, Continue)
        | true, false -> Ok (BatSet.String.add taken seen, visit environment) )
    | {target; binding} :: rest ->
        let* handle = resolve scope target in
        let* generative = Protocols.Generative.require handle in
        let* cursor = Protocols.Generative.generate generative (pushed environment binding) in
        Live.opened live cursor;
        Fun.protect
          ~finally:(fun () -> Live.closed live cursor)
          (fun () ->
            let* scan = Protocols.Cursor.require cursor in
            let rec drain seen =
              let* tuple = Protocols.Cursor.next scan in
              match tuple with
              | None -> Ok (seen, Continue)
              | Some tuple -> (
                  let* extended = extend target binding environment tuple in
                  match extended with
                  | None -> drain seen
                  | Some environment -> (
                      let* seen, step = walk seen environment rest in
                      match step with Stop -> Ok (seen, Stop) | Continue -> drain seen ) )
            in
            drain seen )
  in
  walk BatSet.String.empty environment quantifiers |> Result.map snd

type expression = {label: string; comprehension: comprehension; state: scope}

let rendered {label; comprehension; _} =
  let expression = function
    | Var name -> "?" ^ name
    | Const value -> "=" ^ Concepts.Value.to_string value
  in
  let quantifier {target; binding} =
    BatMap.String.enum binding
    |> BatEnum.map (fun (attribute, held) -> attribute ^ ":" ^ expression held)
    |> BatList.of_enum
    |> String.concat ";"
    |> Printf.sprintf "%s[%s]" (Kernel.Path.to_string target)
  in
  let rec formula = function
    | Truth truth -> if truth then "T" else "F"
    | Not inner -> Printf.sprintf "!(%s)" (formula inner)
    | And (left, right) -> Printf.sprintf "&(%s,%s)" (formula left) (formula right)
    | Or (left, right) -> Printf.sprintf "|(%s,%s)" (formula left) (formula right)
    | Eq {left; right} -> Printf.sprintf "eq(%s,%s)" (expression left) (expression right)
    | Exists {quantifiers; body} ->
        Printf.sprintf "E(%s,%s)"
          (List.map quantifier quantifiers |> String.concat "")
          (formula body)
  in
  label ^ "/" ^ formula (Exists comprehension)

let provenance {quantifiers; _} variable =
  List.concat_map
    (fun {target; binding} ->
      BatMap.String.enum binding
      |> BatEnum.filter_map (fun (attribute, expression) ->
          match expression with
          | Var name when String.equal name variable ->
              Some {Protocols.Schematics.source= Kernel.Path.to_list target; attribute}
          | Var _ | Const _ -> None )
      |> BatList.of_enum )
    quantifiers

let unknown_domain = ""

let domain_of state origins =
  let open Utilities.Result in
  match origins with
  | {Protocols.Schematics.source; attribute} :: _ -> (
      let* handle = resolve state (Kernel.Path.of_list source) in
      match Protocols.Schematics.from handle with
      | None -> Ok unknown_domain
      | Some schematics -> (
          let* description = Protocols.Schematics.describe schematics in
          match description with
          | Protocols.Schematics.Relation description ->
              BatMap.String.find_opt attribute description
              |> Option.fold ~none:unknown_domain ~some:(fun attribute ->
                  attribute.Protocols.Schematics.domain )
              |> Result.ok
          | Protocols.Schematics.Multigroup _ | Protocols.Schematics.Tuple _ -> Ok unknown_domain )
      )
  | [] -> Ok unknown_domain

module Derivation = struct
  type plan = expression

  let identity plan = rendered plan |> Bytes.of_string |> Concepts.Hash.hash_of_bytes

  let describe {comprehension; state; _} =
    attributes_of comprehension
    |> BatSet.String.elements
    |> List.map (fun variable ->
        let origins = provenance comprehension variable in
        domain_of state origins
        |> Result.map (fun domain -> variable, {Protocols.Schematics.domain; provenance= origins}) )
    |> Utilities.List.sequence
    |> Result.map BatMap.String.of_list

  let modes {comprehension; _} =
    let supplied = free (Exists comprehension) |> BatSet.String.elements in
    Ok
      (Concepts.Mode.of_list
         [ Concepts.Mode.decides_when (attributes_of comprehension |> BatSet.String.elements);
           Concepts.Mode.generates_when supplied Concepts.Cardinality.Finite ] )

  let generate {label; comprehension; state} binding =
    let open Utilities.Result in
    let heading = attributes_of comprehension in
    let tuple_of environment =
      { Concepts.Tuple.type_= label;
        attributes= BatMap.String.filter (fun name _ -> BatSet.String.mem name heading) environment
      }
    in
    let live = Live.none () in
    let produce ~yield =
      let* _ =
        assignments ~live state binding comprehension ~visit:(fun environment ->
            yield (tuple_of environment);
            Continue )
      in
      Ok ()
    in
    Ok (Kernel.Generator.cursor_of ~on_release:(fun () -> Live.abandoned live) produce)
end

module Derived = Kernel.EphemeralRelation.Make (Derivation)

module Program = Protocols.Program.Make (struct
  type t = expression
end)

let execute expression = Derived.derive expression

class evaluator =
  object (self)
    inherit Kernel.Lifecycle.null
    inherit Kernel.Identity.of_id
    method invoke = execute
    method protocols : Protocols.Handle.protocol list = [Program.make self]
  end

let make () = new evaluator |> Protocols.Handle.make

type t = {name: string; body: formula}
type change = Assertion | Retraction

let declare ~name body =
  let uncovered = free body in
  if BatSet.String.is_empty uncovered then Ok {name; body}
  else Error (Error.open_constraint name (BatSet.String.enum uncovered |> BatList.of_enum))

let name {name; _} = name
let body {body; _} = body

(* Decker: a denial yields its own quantifiers, any other closed
   formula denies itself into degree zero. *)
let denial = function
  | Not (Exists comprehension) -> comprehension
  | formula -> {quantifiers= []; body= Not formula}

let violations {name; body} state = {label= name; comprehension= denial body; state}

let relevant {body; _} ~relation ~change =
  match List.find_opt (at relation) (relevance body) with
  | None -> false
  | Some (_, Both) -> true
  | Some (_, Negative) -> change = Assertion
  | Some (_, Positive) -> change = Retraction

let with_handle handle body =
  Fun.protect ~finally:(fun () -> Protocols.Handle.release handle) (fun () -> body handle)

let vacant relation =
  let open Utilities.Result in
  let* enumerable = Protocols.Enumerable.require relation in
  let* cursor = Protocols.Enumerable.enumerate enumerable in
  with_handle cursor (fun cursor ->
      let* scan = Protocols.Cursor.require cursor in
      let* witness = Protocols.Cursor.next scan in
      Ok (Option.is_none witness) )

let satisfied interpreter constrains state =
  let open Utilities.Result in
  let* relation = Program.invoke interpreter (violations constrains state) in
  with_handle relation vacant

let admits interpreter state constraints =
  let open Utilities.Result in
  List.fold_left
    (fun acc constrains ->
      let* () = acc in
      let* upheld = satisfied interpreter constrains state in
      if upheld then Ok () else Error (Error.violated (name constrains)) )
    (Ok ()) constraints
