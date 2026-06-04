#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <ranges>

/**
 * @file Types.h
 * @brief Shared enum types and core data types used by the runtime.
 */

/** @brief Runtime object categories known by the object manager. */
enum OBJECT_TYPE {
    /** A database snapshot grouping relations and tuples. */
    MULTIGROUP,
    /** A relation object backed by physical storage. */
    RELATION,
    /** An attribute object (schema metadata). */
    ATTRIBUTE,
    /** A transaction object. */
    TRANSACTION,
    /**
     * A relation whose tuples are produced on demand by a generator function
     * rather than read from physical storage. Behaves like a RELATION in every
     * other respect: owns a `merkle_root`, has mutable schema, composes into its
     * multigroup's hash, and may be opened, scanned, and pinned through the
     * same handle pipeline.
     *
     * The generator receives unsigned-int paginators (offset, limit) plus any
     * bound argument values written by an upstream JOIN, and yields tuples.
     * Cardinality may be finite (e.g. a projection over a stored relation) or
     * AlephZero (e.g. the eq builtin). The object_type for this label must be
     * an ephemeral_object_type.
     *
     * Tracked as a distinct label — rather than collapsed into RELATION —
     * for three reasons:
     *   1. Sakura distinguishes generated relations as a separate subclass at
     *      the wire layer, even though the runtime treats them uniformly.
     *   2. They have no physical tuple-storage backend; reads always go
     *      through the generator.
     *   3. They carry a dependency list of base relation paths they are
     *      defined atop of. This drives structural reference counting (a
     *      base relation cannot be GC'd while an ephemeral relation depends
     *      on it) and is the foundation for attribute-level provenance
     *      tracking added later.
     */
    EPHEMERAL_RELATION,
    /**
     * A named mutable reference to a multigroup snapshot, analogous to a git
     * branch. A BRANCH object carries a `target_hash` — the merkle_root of
     * the snapshot it currently points at — and nothing else.
     *
     * Branch objects are the entry point for database connections: a client
     * opens a handle to /system/branches/<name>, reads target_hash, and uses
     * that hash to open the snapshot at /system/snapshots/<hash>. Multigroup
     * state is reconstructed by walking the content-addressed graph from
     * that snapshot, not by deserializing bytes attached to the branch.
     *
     * The `exclusive` flag on the object_type should be set to true so that
     * LifecycleManager::Contention serializes concurrent writers.
     */
    BRANCH,
    /**
     * A per-connection runtime context. SESSION objects own the
     * connection_context pointer (auth metadata, etc.) and a map of per-session
     * branch overrides: `branch_name -> target_hash`. Overrides let one
     * connection observe a different snapshot for a branch than the global
     * HEAD without affecting other sessions.
     *
     * Sessions are identified by random 256-bit hex hashes minted at
     * rnt_session_open. The hash is opaque to the caller and is the only
     * handle for subsequent rnt_session_* calls. SESSION objects live at
     * /system/sessions/<hash>; the resolver consults
     * /system/sessions/<hash>/branches/<n> first and falls back to the global
     * /system/branches/<n> when there is no override.
     */
    SESSION,
    /**
     * The content-addressed Merkle<string> root of a branch's multigroup map.
     * A BRANCH points at a BRANCH_TREE via target_hash; the tree maps
     * `mg_name -> mg_hash` and is paged at resolve time to translate
     * `/system/branches/<n>/<mg>/<rel>` into `/system/snapshots/<mg_hash>/<rel>`.
     *
     * BRANCH_TREE objects live at `/system/branch_trees/<hash>`. They are
     * immutable (disposable=false, exclusive=false) and pinned by the BRANCH
     * objects that reference them; the mgs they reference are in turn pinned
     * by the BRANCH_TREE via LifecycleManager::CascadeBranchTree at GC time.
     * The same blob is reused across all branches and session overrides
     * that share a tip.
     */
    BRANCH_TREE
};

/** @brief Operations that may be supported by an object type. */
enum METHOD {
    /** Opens an object and creates an authorized handle. */
    OPEN,
    /** Closes a previously opened handle. */
    CLOSE,
    /** Parses through a secondary namespace. */
    PARSE,
    /** Performs security checks. */
    SECURITY
};

/** @brief Claims granted to an authenticated connection. */
enum AUTH_CLAIM {
    /** Permission to read object state. */
    READ,
    /** Permission to mutate object state. */
    WRITE
};

/** @brief Authentication strategies supported by the permissions layer. */
enum AUTH_METHOD {
    /** Certificate-based authentication. */
    CERTIFICATE,
    /** Plain-text authentication. */
    PLAIN_TEXT
};

namespace nt {
    /** @brief A single named value in a tuple, produced by the cursor layer. */
    struct Attribute {
        std::string name;
        std::string value;
    };

    /**
     * @brief A single row of data streamed lazily from the cursor layer.
     *
     * Follows the Volcano pull model: callers repeatedly call Next() to consume
     * one attribute at a time. Returns nullptr when all attributes are exhausted.
     */
    class Tuple {
    public:
        explicit Tuple(std::vector<Attribute> attributes) {
            for (auto &attr : attributes) attributes_[attr.name] = attr.value;
            this->Reset();
        }

        /** @brief Returns the next attribute, or nullptr when exhausted. */
        const Attribute* Next() {
            if (iter_ == attributes_.end()) return nullptr;
            current_attr_ = {iter_->first, iter_->second};
            iter_++;
            return &current_attr_;
        }

        void Reset() {
            iter_ = attributes_.begin();
        }

        const std::string operator[](std::string key) {
            return attributes_[key];
        }

        const auto attrs() const {
          auto view =
              attributes_ |
              std::views::transform([](std::pair<std::string, std::string> p) {
                  return (Attribute){ p.first, p.second };
              });
          return view;
        }

    private:
        std::unordered_map<std::string, std::string> attributes_{};
        std::unordered_map<std::string, std::string>::iterator iter_;
        Attribute current_attr_;
    };
} // namespace nt
