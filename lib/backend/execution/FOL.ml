(** Compiles relational plans ([Plan.t]) into a push-based fold and runs
    them through capability-checked handles ([Managers.Handler.HANDLER]).

    Each [Scan] opens a handle on its relation — admitted only when the
    supplied [Managers.Permission.capability] authorizes it — and pulls
    tuples through a cursor whose lifetime is bounded by [with_cursor].
    Tuples are pushed to a [yield] continuation rather than returned as a
    lazy sequence, so no cursor outlives the scope that opened it. [Join]
    re-scans its inner side once per outer tuple by re-applying the
    compiled pusher to a fresh binding. Only [Materialize] keeps anything
    between runs, because it caches. *)

(** The operator tree. One constructor per operator, holding its
    description and no runtime state. *)
module Plan = struct
  (** One [args] segment. [args] feed an ephemeral relation's generator
      and are ignored for stored relations.
      [Var "x"] is an attribute name. It resolves to the outer tuple's
      value for ["x"] ([Value.value]).
      [Const v] is a literal value ([Value.value]). *)
  type path_arg = Var of string | Const of Concepts.Value.value

  type t =
    (* [path] is the relation's namespace address: fixed strings that
       [Object.find] walks. [args] are ephemeral generator inputs, not
       part of the namespace. *)
    | Scan of {path: Concepts.Path.t; args: path_arg BatFingerTree.t}
    (* Natural join: matches on the attributes [left] and [right] share,
       coalescing them; attributes on one side only impose no condition. *)
    | Natural of {left: t; right: t}
    | Take of {limit: int; from: t}
    | Project of {attrs: BatSet.String.t; from: t}
    | Materialize of t
    | Rename of {attrs: string BatMap.String.t; from: t}
    | Union of t BatFingerTree.t
end

type control = Continue | Stop
(** Whether a consumer wants more tuples ([Continue]) or has stopped
    ([Stop]). Returned by a [yield] continuation and propagated up. *)

(** Condition builders for execution errors. *)
module Error = struct
  open Concepts.Condition

  (** A [Var] named [name] but no such attribute is bound in the outer
      tuple. *)
  let unbound_variable name =
    condition "unbound-variable"
      (Printf.sprintf "path variable %S is not bound in the enclosing tuple" name)
      ("variable" |=| Concepts.Value.String name)
end

(** [resolve args bindings] turns an [args] template into the value
    vector fed to a relation's generator: each [Var] becomes the value
    bound to that attribute, each [Const] stays as is.
    @param args argument template.
    @param bindings tuple supplying the variable values.
    @return the resolved argument values, or [unbound_variable] when a
    [Var] has no binding. *)
let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Concepts.Tuple.t) :
    (Concepts.Value.value BatFingerTree.t, Concepts.Condition.condition) result =
  let open Utilities.Result in
  BatFingerTree.fold_left
    (fun acc arg ->
      let* acc = acc in
      match arg with
      | Plan.Const value -> Ok (BatFingerTree.snoc acc value)
      | Plan.Var name ->
         (match Concepts.Tuple.access name bindings with
          | Some value -> Ok (BatFingerTree.snoc acc value)
          | None -> Error (Error.unbound_variable name)))
    (Ok BatFingerTree.empty)
    args

type yield = Concepts.Tuple.t -> (control, Concepts.Condition.condition) result
(** A tuple consumer. Returns [Continue] to keep receiving, [Stop] to end
    the scan, or a condition to abort it. *)

type pusher =
  bindings:Concepts.Tuple.t -> yield:yield -> (control, Concepts.Condition.condition) result
(** A compiled operator: pushes its tuples to [yield] under a binding
    tuple, and reports whether the consumer stopped or an error arose. *)

(** Compiles and runs plans by pushing tuples through capability-checked
    handles ([Managers.Handler.HANDLER]). Relation paths, authorization,
    Merkle paging, and the object namespace all live behind that seam.
    This module never touches storage or the object tree directly. *)
module Make (Handler : Managers.Handler.HANDLER) = struct
  (** [drain cursor ~yield] pushes every tuple from [cursor] to [yield],
      stopping when [yield] returns [Stop] or the cursor errors. *)
  let rec drain cursor ~yield =
    match Handler.next cursor with
    | Error condition -> Error condition
    | Ok None -> Ok Continue
    | Ok (Some tuple) ->
       (match yield tuple with
        | Ok Continue -> drain cursor ~yield
        | other -> other)

  (** [replay rows ~yield] pushes each of [rows] to [yield] in order,
      stopping on [Stop] or error. *)
  let rec replay rows ~yield =
    match rows with
    | [] -> Ok Continue
    | tuple :: rows ->
       (match yield tuple with
        | Ok Continue -> replay rows ~yield
        | other -> other)

  (** [compile handler cap plan] turns [plan] into a pusher.
      @return the compiled pusher. *)
  let rec compile handler cap : Plan.t -> pusher = function
    | Scan {path; args} ->
       fun ~bindings ~yield ->
       (match resolve args bindings with
        | Error condition -> Error condition
        | Ok args ->
           (match Handler.open_ handler cap ~path ~claim:Managers.Permission.Read with
            | Error condition -> Error condition
            | Ok handle ->
               (match Handler.with_cursor handle ~args (fun cursor -> drain cursor ~yield) with
                | Error condition -> Error condition
                | Ok result -> result)))
    | Project {attrs; from} ->
       let from = compile handler cap from in
       fun ~bindings ~yield ->
       from ~bindings ~yield:(fun tuple -> yield (Concepts.Tuple.project attrs tuple))
    | Rename {attrs; from} ->
       let from = compile handler cap from in
       fun ~bindings ~yield ->
       from ~bindings ~yield:(fun tuple -> yield (Concepts.Tuple.rename attrs tuple))
    | Take {limit; from} ->
       let from = compile handler cap from in
       fun ~bindings ~yield ->
       let remaining = ref limit in
       let stopped = ref false in
       let capped tuple =
         if !remaining <= 0 then Ok Stop
         else begin
           decr remaining ;
           match yield tuple with
           | Ok Stop -> stopped := true ; Ok Stop
           | Ok Continue -> if !remaining <= 0 then Ok Stop else Ok Continue
           | Error condition -> Error condition
         end
       in
       (match from ~bindings ~yield:capped with
        | Error condition -> Error condition
        | Ok _ -> if !stopped then Ok Stop else Ok Continue)
    | Union plans ->
       let compiled = BatFingerTree.map (compile handler cap) plans in
       fun ~bindings ~yield ->
       BatFingerTree.fold_left
         (fun acc from -> match acc with Ok Continue -> from ~bindings ~yield | other -> other)
         (Ok Continue) compiled
    | Natural {left; right} ->
       let left = compile handler cap left and right = compile handler cap right in
       let matches l r =
         BatMap.String.for_all
           (fun name value ->
             match Concepts.Tuple.access name r with
             | Some value' -> value = value'
             | None -> true)
           l
       in
       fun ~bindings ~yield ->
       left ~bindings ~yield:(fun l ->
         right ~bindings:l ~yield:(fun r ->
           if matches l r then yield (Concepts.Tuple.merge l r) else Ok Continue))
    | Materialize from ->
       let from = compile handler cap from in
       let cache = ref None in
       fun ~bindings:_ ~yield ->
       (match !cache with
        | Some rows -> replay rows ~yield
        | None ->
           let buffer = ref [] in
           (match
              from ~bindings:Concepts.Tuple.empty ~yield:(fun tuple ->
                buffer := tuple :: !buffer ; Ok Continue)
            with
            | Error condition -> Error condition
            | Ok _ ->
               let rows = List.rev !buffer in
               cache := Some rows ;
               replay rows ~yield))

  (** [fold handler cap plan ~init ~f] runs [plan] under the empty binding
      and folds [f] over its tuples.
      @return the final accumulator, or the condition that stopped it. *)
  let fold handler cap plan ~init ~f =
    let acc = ref init in
    let yield tuple = acc := f !acc tuple ; Ok Continue in
    match compile handler cap plan ~bindings:Concepts.Tuple.empty ~yield with
    | Ok _ -> Ok !acc
    | Error condition -> Error condition

  (** [to_list handler cap plan] runs [plan] and collects its tuples.
      @return the tuples in order, or the condition that stopped them. *)
  let to_list handler cap plan =
    fold handler cap plan ~init:[] ~f:(fun acc tuple -> tuple :: acc)
    |> Result.map List.rev
end
