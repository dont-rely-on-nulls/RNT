module Make (Store : Abstract.Storage.STORAGE) = struct
  type tree = Object.rnt_object_tree

  let monitor (tree : tree) (path : Concepts.Path.t) : tree =
    Object.update path (fun r -> {r with Object.handle_count= r.Object.handle_count + 1}) tree

  let pin (tree : tree) (path : Concepts.Path.t) : tree =
    Object.update path (fun r -> {r with Object.reference_count= r.Object.reference_count + 1}) tree

  let is_eligible_for_gc (tree : tree) (path : Concepts.Path.t) : bool =
    match Object.find path tree with
    | Some r -> r.Object.handle_count = 0 && r.Object.reference_count = 0
    | None -> false

  let contention (_tree : tree) (_path : Concepts.Path.t) : bool =
    failwith "NOT IMPLEMENTED: read exclusive flag, gate write opener on handle_count"

  let try_collect (_txn : Store.transaction) (_tree : tree) (_path : Concepts.Path.t) :
      (tree, Concepts.Condition.condition) result =
    failwith
      "NOT IMPLEMENTED: if eligible and not BRANCH/SESSION, run cascade then Object.unregister"

  let unmonitor (txn : Store.transaction) (tree : tree) (path : Concepts.Path.t) :
      (tree, Concepts.Condition.condition) result =
    let tree =
      Object.update path
        (fun r ->
          if r.Object.handle_count = 0 then r
          else {r with Object.handle_count= r.Object.handle_count - 1})
        tree
    in
    try_collect txn tree path

  let unpin (txn : Store.transaction) (tree : tree) (path : Concepts.Path.t) :
      (tree, Concepts.Condition.condition) result =
    let tree =
      Object.update path
        (fun r ->
          if r.Object.reference_count = 0 then r
          else {r with Object.reference_count= r.Object.reference_count - 1})
        tree
    in
    try_collect txn tree path

  let collect (txn : Store.transaction) (tree : tree) (path : Concepts.Path.t) :
      (tree, Concepts.Condition.condition) result =
    try_collect txn tree path
end
