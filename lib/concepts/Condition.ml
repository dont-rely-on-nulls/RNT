type properties = (string, Value.value) BatMap.t
type ps = properties -> properties

type condition =
  { name: string;
    message: string;
    backtrace: Printexc.raw_backtrace;
    properties: properties }

let ( |=| ) name value = fun p -> BatMap.add name value p
let ( & ) l r = fun p -> r (l p)
let empty = fun p -> p

let to_string_hum { name; message; properties; backtrace } =
  let properties' =
    properties
    |> BatMap.to_seq
    |> BatSeq.to_string ~first:"" ~last:"" ~sep:"\n" (fun (k, v) -> "\t" ^ k ^ ": " ^ Value.to_string v)
  in
  let backtrace' = Printexc.raw_backtrace_to_string backtrace in
  name ^ ": " ^ message ^ "\n" ^ properties' ^ "\n\nBacktrace:\n" ^ backtrace'
