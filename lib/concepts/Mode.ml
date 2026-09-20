type attribute = string
type attributes = BatSet.String.t
type affordance = Decides | Generates of Cardinality.t
type mode = {bound: attributes; affords: affordance}
type t = mode list

let attributes_of_list = BatSet.String.of_list

let decides_when bound = {bound= attributes_of_list bound; affords= Decides}

let generates_when bound cardinality =
  {bound= attributes_of_list bound; affords= Generates cardinality}

let enumerable cardinality = {bound= BatSet.String.empty; affords= Generates cardinality}

let empty = []
let declare mode declaration = mode :: declaration
let of_list modes = modes
let to_list declaration = declaration

let generation declaration bound =
  List.fold_left
    (fun tightest {bound= declared; affords} ->
      match affords with
      | Generates cardinality when BatSet.String.subset declared bound ->
          Some
            ( match tightest with
            | None -> cardinality
            | Some other -> Cardinality.meet cardinality other )
      | Generates _ | Decides -> tightest )
    None declaration

let decision declaration bound =
  List.exists
    (fun {bound= declared; affords} ->
      match affords with
      | Decides -> BatSet.String.equal declared bound
      | Generates _ -> false )
    declaration
