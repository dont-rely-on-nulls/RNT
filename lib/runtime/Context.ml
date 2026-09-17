module Error = struct
  open Concepts.Condition

  let not_a_directory segment =
    condition "not-a-directory" "A path segment named an object with no Directory protocol"
      ("segment" |=| Concepts.Value.String segment)
end

let resolve { Protocols.Context.root; _ } name = Kernel.Path.lookup root name

let over ~snapshot ~root ?(cancelled = fun () -> false) () =
  { Protocols.Context.snapshot
  ; root
  ; status = (fun () -> if cancelled () then `Cancelled else `Live) }
