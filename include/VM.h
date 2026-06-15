#pragma once

#include "Api.h"
#include "CursorManager.h"
#include "Types.h"

#include <optional>
#include <string>
#include <unordered_set>
#include <vector>

/**
 * @file VM.h
 * @brief Declares the logic execution boundary for relational and higher-order workloads.
 */

namespace nt {
    /**
     * @class VM
     * @brief Hosts the first-order logic (FOL) and second-order logic (SOL) cores.
     *
     * This partitioning exists to ensure retrieval terminates when execution is
     * constrained to first-order logic.
     *
     * - Tarski runtime (FOL): a relational engine that implements Tarski's
     *   relational calculus. It uses a deterministic Volcano-iterator model to
     *   perform relational algebra operations such as joins, projections, and
     *   selects directly against the CursorManager and a prepared plan.
     *
     * - Karuta runtime (SOL): an isolated WAM-based environment for
     *   higher-order logic programming. It handles recursion, choice points, and
     *   other programming constructs that do not guarantee termination.
     *
     * @remark Lazy evaluation and paging strategy
     *
     * Both the Tarski first-order engine and the Karuta second-order engine are
     * strictly pull-based. Data is streamed lazily from the CursorManager to
     * preserve a constant memory footprint regardless of relation size.
     *
     * Pipeline dynamics:
     * - Demand-driven: the Karuta WAM requests a fact only when a goal needs
     *   satisfaction. A request propagates down the algebra tree as a chain of
     *   Next() calls.
     *
     * - Short-circuiting: if the Karuta engine finds a solution or reaches a
     *   failure that invalidates a branch, the Tarski iterator is discarded or
     *   reset without materializing the remaining tuples.
     *
     * - Resource stewardship: by maintaining laziness up to the highest logical
     *   level, the runtime minimizes pressure on ObjectManager and keeps
     *   snapshots pinned through LifecycleManager::Monitor only for the minimum
     *   time required.
     */

    /**
     * @brief One segment of a parameterized relation path in a SCAN node.
     *
     * Var segments are resolved at runtime from the outer tuple of a JOIN:
     * the JOIN writes the bound value into the cursor's args vector before
     * each probe. Const segments are ground literals fixed at plan construction.
     *
     * The resolved args vector is passed to the ephemeral relation's generator
     * (for EPHEMERAL_RELATION cursors) or ignored (for stored RELATION cursors,
     * which need no per-probe parameterization).
     */
    struct PathArg {
        enum class Kind { Var, Const };

        Kind kind;
        std::string name; /**< Attribute name to look up (Var), or literal value (Const). */

        static PathArg Var(std::string attr) {
            return {Kind::Var, std::move(attr)};
        }
        static PathArg Const(std::string val) {
            return {Kind::Const, std::move(val)};
        }
    };

    enum Operation {
        FOL_OPERATION_SCAN = 1,
        FOL_OPERATION_JOIN,
        FOL_OPERATION_TAKE,
        FOL_OPERATION_PROJECT
    };

    /**
     * @brief A node in the Volcano operator tree executed by the Tarski (FOL) runtime.
     *
     * Each node represents one relational algebra operator. The tree is demand-driven:
     * VM::Next() propagates pull requests from root to leaves.
     *
     * Supported operators:
     * - SCAN  : pulls tuples from a pre-opened cursor (stored or ephemeral relation).
     * - JOIN  : nested-loop join. For each outer (left) tuple, resolves scan_args on
     *           the inner (right) SCAN, resets its cursor, and probes it. Works for
     *           both stored relations (full re-scan of inner) and ephemeral relations
     *           (O(1) membership probe when all args are bound).
     * - TAKE  : passes at most take_limit tuples through, then returns nullptr. Use
     *           this to bound scans over AlephZero ephemeral relations.
     * - PROJECT: filters each input tuple to the named attributes in project_attrs.
     */
    struct PlanNode {
        Operation op;
        PlanNode* left = nullptr;
        PlanNode* right = nullptr;

        /**
         * SCAN: pre-opened cursor. For ephemeral relations the JOIN resets it
         * (args, offset, exhausted flag) with resolved args before each probe,
         * overwriting whatever standalone-scan state it opened with.
         */
        CursorManager::cursor* scan_cursor = nullptr;

        /**
         * SCAN: argument template for parameterized relations.
         * Var entries are resolved from the outer JOIN tuple; Const entries
         * are used as-is. The resolved values are written into scan_cursor->args
         * by the JOIN before it calls Next() on this node.
         */
        std::vector<PathArg> scan_args;

        /** TAKE: maximum number of tuples to emit before returning nullptr. */
        std::size_t take_limit = 0;
        std::size_t take_count = 0; /**< Runtime counter; mutable during execution. */

        /** PROJECT: unordered set of attribute names to keep. */
        std::unordered_set<std::string> project_attrs;
        std::optional<Tuple> project_buffer;

        /**
         * JOIN runtime state.
         *
         * join_left holds the current outer tuple while probing the inner
         * (right) side. The pointer is stable for the lifetime of one outer
         * iteration because Next(left) is only called when join_left is reset
         * to nullptr, which happens only after the inner side is exhausted.
         *
         * join_buffer holds the merged output tuple and is overwritten on each
         * successful join. Callers must consume the returned pointer before
         * calling Next() again — same contract as a cursor page pointer.
         */
        Tuple* join_left = nullptr;
        std::optional<Tuple> join_buffer;
    };

    class VM {
      public:
        // TODO: CursorManager should be injected as a shared runtime instance,
        // matching the pattern flagged for HandlerManager and LifecycleManager.
        //
        // A single CursorManager instance supports multiple simultaneous cursors —
        // all iteration state lives in each cursor struct, not in the manager.
        // A JOIN plan, for example, holds two independent cursors (one per SCAN leaf)
        // and both are driven through the same CursorManager reference.
        explicit VM(CursorManager& cursors);

        /**
         * @brief Pulls the next tuple from the plan tree (Tarski/FOL core).
         *
         * Propagates a Next() call down the operator tree:
         * - SCAN  delegates to CursorManager::Next.
         * - JOIN  drives the nested-loop: for each outer tuple it resolves
         *         scan_args on the inner SCAN, resets the inner cursor, and
         *         probes until a match is found or the inner is exhausted.
         * - TAKE  counts emitted tuples and returns nullptr once the limit
         *         is reached.
         * - PROJECT filters an input tuple to the requested attribute names.
         *
         * @param node Root of the plan subtree to evaluate.
         * @return Next matching tuple, or nullptr when the plan is exhausted.
         */
        Tuple* Next(PlanNode* node);

      private:
        CursorManager& cursors_;

        /**
         * Resolves a scan_args template against an outer tuple, producing the
         * concrete args vector to write into the inner cursor before probing.
         */
        static std::vector<std::string> ResolveArgs(const std::vector<PathArg>& tmpl, Tuple* from);

        /** Resets the inner cursor state and writes resolved args into it. */
        static void ResetInner(CursorManager::cursor* c, std::vector<std::string> args);

        /** Merges left and right tuple attributes into node->join_buffer. */
        static Tuple* MergeInto(PlanNode* node, Tuple* left, Tuple* right);
    };
} // namespace nt
