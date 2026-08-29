type protocol = ..

class type obj = object
  method reference : bool
  method release : unit
  method hash : Concepts.Hash.hash
  method protocols : protocol list
end

type t = { valid : bool ref; refers_to : obj }

type 'a interface = { handle : t; interface : 'a }

let object_of { valid; refers_to } =
  if !valid then
    refers_to
  else
    failwith "Attempt to dereference an invalid handle!"

let interface_of handle interface = { handle; interface }

let make o = { valid = ref true; refers_to = (o :> obj) }

let into handle f =
  List.find_map f (object_of handle)#protocols
  |> Option.map (interface_of handle)

let invoke { handle; interface } f =
  let _ = object_of handle in
  f interface

let copy handle =
  let o = object_of handle in
  if o#reference then
    Some (make o)
  else
    None

let equal h1 h2 =
  Concepts.Hash.hash_equals (object_of h1)#hash (object_of h2)#hash

let release ({ valid; _ } as handle) =
  let o = object_of handle in
  valid := false;
  o#release
