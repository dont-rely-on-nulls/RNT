(** The cursor layer the FOL VM pulls tuples through.

    Modelled on the C++ [nt::CursorManager]. It owns the storage
    backend and the object registry, resolves a relation's object path
    through a handle, seeds the relation's Merkle root (stored) or
    generator (ephemeral), and pages tuples on demand. The VM depends
    only on this signature and never reaches the object namespace or
    storage backend directly. *)
module type CURSOR_MANAGER = sig
  (** A cursor manager instance. Owns the storage backend and the
      object registry needed to resolve and page relations. *)
  type t

  (** A stateful iterator over one relation's tuples. Holds one page at
      a time and pages on [next]. *)
  type cursor

  (** [open_ t ~path ~args] opens a cursor on the relation at [path] in
      the object namespace. [args] are the resolved generator argument
      values for an ephemeral relation and are ignored for stored
      relations.
      @return the cursor, or a condition when [path] does not resolve
      to a relation. *)
  val open_:
    t ->
    path:string BatFingerTree.t ->
    args:Concepts.Value.value BatFingerTree.t ->
    (cursor, Concepts.Condition.condition) result

  (** [next cursor] pulls the next tuple, fetching the next page when
      the current one runs out.
      @return the next tuple, [None] at exhaustion, or a condition on a
      paging failure. *)
  val next: cursor -> (Concepts.Tuple.t option, Concepts.Condition.condition) result

  (** [close cursor] releases the cursor's resources: unpins its
      snapshot and frees its page. *)
  val close: cursor -> unit
end
