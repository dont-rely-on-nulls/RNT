type protocol = ..

module Error = struct
  open Concepts.Condition

  let unimplemented_protocol obj_name =
    condition "unimplemented-protocol"
      "A required protocol was not implemented by the specified object"
      ("object" |=| Concepts.Value.String obj_name)
end

class type obj = object
  method reference : bool
  method release : unit
  method is_managed : bool
  method hash : Concepts.Hash.hash
  method to_string : string
  method protocols : protocol list
end

type t = {valid: bool Atomic.t; refers_to: obj; allocated_at: Printexc.raw_backtrace}
type 'a interface = {handle: t; interface: 'a}

let object_of {valid; refers_to; _} =
  if Atomic.get valid then refers_to else failwith "Attempt to dereference an invalid handle!"

let to_string h =
  let o = object_of h in
  "#<" ^ o#to_string ^ " " ^ Concepts.Hash.to_hum_string o#hash ^ ">"

let invalidate {valid; _} = Atomic.compare_and_set valid true false

let release handle =
  let o = object_of handle in
  if invalidate handle then o#release

let on_gc ({valid; refers_to; allocated_at} as h) =
  (* TODO: get rid of this on release builds *)
  if refers_to#is_managed && Atomic.get valid then begin
    Logger.(log Warn ("Leaking handle to managed object " ^ to_string h));
    Logger.(
      log Warn
        (BatString.nreplace (* bleh *)
           ~str:(Printexc.raw_backtrace_to_string allocated_at)
           ~sub:"Raised by primitive operation" ~by:"Allocated" ) );
    release h
  end

type _ Effect.t += Autorelease : t -> unit Effect.t | Keep : t -> unit Effect.t

let with_autorelease f =
  let hs = Atomic.make BatSet.empty in
  Fun.protect
    ~finally:(fun () -> Atomic.get hs |> BatSet.iter release)
    (fun () ->
      try f () with
      | effect Autorelease h, k ->
          Utilities.Atomic.swap hs (fun ft -> BatSet.add h ft) |> ignore;
          Effect.Deep.continue k ()
      | effect Keep h, k ->
          Utilities.Atomic.swap hs (fun ft -> BatSet.remove h ft) |> ignore;
          Effect.Deep.continue k () )

let keep h = Effect.perform (Keep h); h
let autorelease h = Effect.perform (Autorelease h); h
let interface_of handle interface = {handle; interface}

let make o =
  let h =
    {valid= Atomic.make true; refers_to= (o :> obj); allocated_at= Printexc.get_callstack 256}
  in
  Gc.finalise on_gc h; h

let into handle f = List.find_map f (object_of handle)#protocols |> Option.map (interface_of handle)

let invoke {handle; interface} f =
  let _ = object_of handle in
  f interface

let from {handle; _} = handle

let copy handle =
  let o = object_of handle in
  if o#reference then Some (make o) else None

let move handle =
  let o = object_of handle in
  invalidate handle |> ignore;
  make o

let equal h1 h2 = Concepts.Hash.hash_equals (object_of h1)#hash (object_of h2)#hash
let hash h = (object_of h)#hash
let protocols h = (object_of h)#protocols
let require f h = Option.to_result ~none:(Error.unimplemented_protocol (to_string h)) (f h)
