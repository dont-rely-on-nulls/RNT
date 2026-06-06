#pragma once

#include "Api.h"
#include "HandlerManager.h"
#include "IStorageBackend.h"
#include "LifecycleManager.h"
#include "ObjectManager.h"
#include "Types.h"

#include <cstddef>
#include <string>
#include <vector>

/**
 * @file CursorManager.h
 * @brief Declares paging and cursor orchestration for query execution.
 */

namespace nt {
    /**
     * @class CursorManager
     * @brief Orchestrates paginated data retrieval from a storage backend.
     *
     * CursorManager depends only on IStorageBackend. The concrete backend
     * (SqliteBackend, InMemoryBackend, …) is injected at construction time.
     *
     * Tuples are never loaded all at once. Open() fetches the first page;
     * each subsequent Next() call transparently fetches the next page from
     * the backend once the current page is exhausted.
     *
     * Pagination is driven by the Merkle B-tree: each cursor carries the hex
     * hash of the relation's Merkle root at open time, and LoadPage calls
     * Merkle::Page(backend, merkle_root, fetch_offset, PAGE_SIZE) to retrieve
     * the next page of tuple hashes without loading sibling subtrees.
     */
    class CursorManager {
      public:
        static constexpr std::size_t PAGE_SIZE = 1;

        /**
         * @brief Constructs a CursorManager.
         *
         * The @p lifecycles and @p objects references are optional: when
         * left null the cursor performs no snapshot pinning (this matches the
         * test fixtures, which register relations at synthetic paths with no
         * /system/snapshots ancestor). When both are provided, Open finds the
         * resolved snapshot for the handle's relation and Pins it for the
         * cursor's lifetime, releasing the pin in Close.
         */
        explicit CursorManager(IStorageBackend& backend, LifecycleManager* lifecycles = nullptr,
                               ObjectManager* objects = nullptr);

        /**
         * @brief Active scan state for a single relation.
         *
         * Holds one page of deserialized tuples at a time. When page_position
         * reaches the end of the page, Next() discards the page and fetches
         * the next one from the backend.
         *
         * The pointer returned by Next() is valid only until the next Next()
         * or Close() call — a page replacement invalidates all prior pointers.
         *
         * merkle_root is seeded from ObjectManager::Relation::merkle_root at
         * open time and does not change during iteration; the cursor reads the
         * snapshot captured when it was opened.
         *
         * Notably the cursor does NOT keep a pointer to the HandlerManager
         * handle it was opened from. Everything Next() needs — the relation
         * type, the merkle_root, and the ephemeral generator function — is
         * captured at Open time, so closing the handle before the cursor is
         * exhausted is safe (the API contract still says to close the cursor
         * first, but a violation no longer dereferences a freed handle).
         */
        struct cursor {
            /**
             * Hex hash of the relation's Merkle B-tree root node.
             * Empty string means the relation contains no tuples.
             */
            std::string merkle_root;
            /**
             * Bound argument values for EPHEMERAL_RELATION cursors.
             * Written by the JOIN operator before each probe; ignored for
             * stored RELATION cursors.
             */
            std::vector<std::string> args;
            std::vector<Tuple> page;
            std::size_t page_position = 0;
            std::size_t fetch_offset = 0; // next Merkle::Page() call starts here
            bool exhausted = false;
            /**
             * True for EPHEMERAL_RELATION cursors; selects the generator-driven
             * page fetch path instead of Merkle B-tree paging.
             */
            bool is_ephemeral = false;
            /**
             * Generator function for ephemeral cursors. Copied from the
             * ephemeral_object_type at Open time, so the cursor remains valid
             * even if the source registry entry is later torn down (the
             * snapshot pin held in pinned_snapshot prevents that today, but
             * the copy makes the cursor independent regardless).
             */
            ObjectManager::ephemeral_object_type::Generator generator;
            /**
             * Borrowed pointer to the snapshot the cursor is pinning.
             * Non-null only when a /system/snapshots/<H>/<n>
             * ancestor was found at Open time and LifecycleManager was
             * available. Close unpins it.
             */
            ObjectManager::registry* pinned_snapshot = nullptr;
        };

        /**
         * @brief Opens a cursor on the relation referenced by the handle.
         *
         * Fetches the first page immediately for non-empty relations. Returns
         * a valid exhausted cursor when @p merkle_root is empty (empty relation).
         * Returns nullptr when the handle does not refer to a RELATION or
         * EPHEMERAL_RELATION.
         *
         * @param handle       Open RELATION or EPHEMERAL_RELATION handle.
         * @param merkle_root  Hex hash of the relation's Merkle root at open
         *                     time. Ignored for EPHEMERAL_RELATION handles.
         */
        cursor* Open(HandlerManager::handle* handle, const std::string& merkle_root = "");

        /**
         * @brief Pulls the next tuple from the cursor.
         *
         * Fetches the next page from the backend transparently when the
         * current page is exhausted. Returns nullptr when all pages are done.
         */
        Tuple* Next(cursor* cursor);

        /**
         * @brief Closes the cursor and releases its resources.
         * @param cursor Cursor to close.
         */
        void Close(cursor* cursor);

      private:
        IStorageBackend& backend_;
        LifecycleManager* lifecycles_ = nullptr;
        ObjectManager* objects_ = nullptr;

        /**
         * Fetches a page of hashes via Merkle::Page, resolves each from the
         * KV store, and deserializes them into cursor->page. Clears the
         * existing page.  Advances fetch_offset by the number of hashes
         * returned; sets exhausted when fewer than PAGE_SIZE hashes come back.
         */
        void LoadPage(cursor* c);
    };
} // namespace nt
