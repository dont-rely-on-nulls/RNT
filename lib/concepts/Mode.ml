type attributes = BatSet.String.t
type mode = {bound: attributes; yields: Cardinality.t}
type t = mode list

let mode bound yields = {bound= BatSet.String.of_list bound; yields}

let generation modes bound =
  List.fold_left
    (fun tightest {bound= declared; yields} ->
      if BatSet.String.subset declared bound then
        Some (Option.fold ~none:yields ~some:(Cardinality.meet yields) tightest)
      else tightest )
    None modes

let exhaustible modes bound =
  Option.fold ~none:false ~some:Cardinality.exhaustible (generation modes bound)

let project attributes = List.filter (fun {bound; _} -> BatSet.String.subset bound attributes)
