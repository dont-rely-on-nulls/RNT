#include <catch2/catch_test_macros.hpp>

#include "RNT_C_API.h"

#include <cstring>
#include <string>

// ---------------------------------------------------------------------------
// End-to-end C API tests covering step 2 (Branch hash-pointer), step 3+4
// (copy-on-write writes and resolver wiring through rnt_open_handle), and
// step 5 (session lifecycle and overrides).
//
// The C API holds a single process-global runtime; rnt_init is idempotent.
// Each test uses unique branch and session identifiers so state from one
// test does not affect another.
// ---------------------------------------------------------------------------

namespace {
    struct InitGuard {
        InitGuard() {
            REQUIRE(rnt_init("memory", nullptr) == 0);
        }
    };

    std::string take_string(char* p) {
        std::string s = p ? p : "";
        rnt_free_string(p);
        return s;
    }
} // namespace

// ---------------------------------------------------------------------------
// Step 2 — Branch hash-pointer model
// ---------------------------------------------------------------------------

TEST_CASE("rnt_register_branch with empty target creates an unborn branch",
          "[step2][capi][branch]") {
    InitGuard _;
    const char* path = "/system/branches/test_step2_unborn";
    REQUIRE(rnt_register_branch(path, "") == 0);

    rnt_handle_t h = rnt_open_handle(path, nullptr);
    REQUIRE(h != nullptr);

    char* target = nullptr;
    REQUIRE(rnt_branch_target(h, &target) == 0);
    REQUIRE(take_string(target) == "");

    REQUIRE(rnt_close_handle(h) == 0);
}

TEST_CASE("rnt_register_branch rejects an unregistered target hash", "[step2][capi][branch]") {
    InitGuard _;
    REQUIRE(rnt_register_branch(
                "/system/branches/test_step2_bad_init",
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != 0);
}

TEST_CASE("rnt_branch_advance rejects an unregistered target hash", "[step2][capi][branch]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step2_bad_advance";
    REQUIRE(rnt_register_branch(bpath, "") == 0);

    REQUIRE(rnt_branch_advance(
                bpath, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != 0);

    // Target unchanged.
    rnt_handle_t h = rnt_open_handle(bpath, nullptr);
    REQUIRE(h != nullptr);
    char* target = nullptr;
    REQUIRE(rnt_branch_target(h, &target) == 0);
    REQUIRE(take_string(target) == "");
    rnt_close_handle(h);
}

TEST_CASE("Writing a tuple advances the branch to a new snapshot", "[step2][step3][capi][branch]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step2_advance";
    const char* rpath = "/system/branches/test_step2_advance/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    // After register_relation, the branch is bound to the first snapshot.
    rnt_handle_t h = rnt_open_handle(bpath, nullptr);
    REQUIRE(h != nullptr);
    char* first = nullptr;
    REQUIRE(rnt_branch_target(h, &first) == 0);
    const std::string first_hash = take_string(first);
    REQUIRE(first_hash.size() == 64);
    rnt_close_handle(h);

    // A tuple write advances the branch again.
    char* tuple_hash = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &tuple_hash) == 0);
    rnt_free_string(tuple_hash);

    h = rnt_open_handle(bpath, nullptr);
    REQUIRE(h != nullptr);
    char* second = nullptr;
    REQUIRE(rnt_branch_target(h, &second) == 0);
    const std::string second_hash = take_string(second);
    rnt_close_handle(h);

    REQUIRE(second_hash.size() == 64);
    REQUIRE(second_hash != first_hash);
}

// ---------------------------------------------------------------------------
// Step 3+4 — Copy-on-write writes and resolver wiring
// ---------------------------------------------------------------------------

TEST_CASE("link_tuple commits a new snapshot and relation_root reflects it", "[step3][capi][cow]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step3_link";
    const char* rpath = "/system/branches/test_step3_link/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    // Empty relation: root is "".
    char* root = nullptr;
    REQUIRE(rnt_relation_root(rpath, &root) == 0);
    REQUIRE(take_string(root) == "");

    char* tuple_hash = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\nname=alpha\n", &tuple_hash) == 0);
    REQUIRE(tuple_hash != nullptr);
    rnt_free_string(tuple_hash);

    REQUIRE(rnt_relation_root(rpath, &root) == 0);
    const std::string new_root = take_string(root);
    REQUIRE(new_root.size() == 64); // a real Merkle root now
}

TEST_CASE("unlink_tuple and clear_relation walk back through new snapshots", "[step3][capi][cow]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step3_unlink";
    const char* rpath = "/system/branches/test_step3_unlink/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    char* th = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &th) == 0);
    const std::string tuple_hash = take_string(th);

    char* root = nullptr;
    REQUIRE(rnt_relation_root(rpath, &root) == 0);
    REQUIRE(take_string(root) != "");

    REQUIRE(rnt_unlink_tuple(rpath, tuple_hash.c_str()) == 0);
    REQUIRE(rnt_relation_root(rpath, &root) == 0);
    REQUIRE(take_string(root) == "");

    // After re-link and clear, root is empty again.
    REQUIRE(rnt_link_tuple(rpath, "id=2\n", &th) == 0);
    rnt_free_string(th);
    REQUIRE(rnt_clear_relation(rpath) == 0);
    REQUIRE(rnt_relation_root(rpath, &root) == 0);
    REQUIRE(take_string(root) == "");
}

TEST_CASE("rnt_open_handle resolves branch-relative paths to snapshot relations",
          "[step4][capi][resolver]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step4_resolve";
    const char* rpath = "/system/branches/test_step4_resolve/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    char* tuple_hash = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &tuple_hash) == 0);
    rnt_free_string(tuple_hash);

    // Opening the branch-relative path resolves to the snapshot-bound entry,
    // and a cursor reads the tuple just written.
    rnt_handle_t h = rnt_open_handle(rpath, nullptr);
    REQUIRE(h != nullptr);
    rnt_cursor_t c = rnt_cursor_open(h);
    REQUIRE(c != nullptr);

    char* row = nullptr;
    REQUIRE(rnt_cursor_next(c, &row) == 1);
    REQUIRE(row != nullptr);
    rnt_free_string(row);

    // Exhausted on the next call.
    REQUIRE(rnt_cursor_next(c, &row) == 0);
    REQUIRE(row == nullptr);

    rnt_cursor_close(c);
    rnt_close_handle(h);
}

TEST_CASE("Reading an unborn branch's relation fails cleanly", "[step4][capi][resolver]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step4_unborn";
    REQUIRE(rnt_register_branch(bpath, "") == 0);

    // No relation registered: relation_root miss returns nonzero.
    char* root = nullptr;
    REQUIRE(
        rnt_relation_root("/system/branches/test_step4_unborn/multigroups/public/relations/missing",
                          &root) != 0);
}

// ---------------------------------------------------------------------------
// Step 5 — Session lifecycle and overrides
// ---------------------------------------------------------------------------

TEST_CASE("Each rnt_session_open returns a distinct 64-char hex hash", "[step5][capi][session]") {
    InitGuard _;
    char* a = nullptr;
    char* b = nullptr;
    REQUIRE(rnt_session_open(nullptr, &a) == 0);
    REQUIRE(rnt_session_open(nullptr, &b) == 0);
    const std::string ha = take_string(a);
    const std::string hb = take_string(b);
    REQUIRE(ha.size() == 64);
    REQUIRE(hb.size() == 64);
    REQUIRE(ha != hb);

    REQUIRE(rnt_session_close(ha.c_str()) == 0);
    REQUIRE(rnt_session_close(hb.c_str()) == 0);
}

TEST_CASE("rnt_session_close on an unknown hash fails", "[step5][capi][session]") {
    InitGuard _;
    REQUIRE(rnt_session_close("0000000000000000000000000000000000000000000000000000000000000000") !=
            0);
}

TEST_CASE("Session override redirects branch-relative reads to a different snapshot",
          "[step5][capi][session][resolver]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step5_override";
    const char* rpath = "/system/branches/test_step5_override/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    // Snapshot S1: one tuple.
    char* th = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &th) == 0);
    rnt_free_string(th);

    // Capture S1's hash and pin it via a session override before the next
    // commit — without the override the next link_tuple would cascade-collect
    // S1 as soon as the branch advances away from it.
    rnt_handle_t bh = rnt_open_handle(bpath, nullptr);
    REQUIRE(bh != nullptr);
    char* target = nullptr;
    REQUIRE(rnt_branch_target(bh, &target) == 0);
    const std::string s1 = take_string(target);
    rnt_close_handle(bh);

    char* sess = nullptr;
    REQUIRE(rnt_session_open(nullptr, &sess) == 0);
    const std::string sid = take_string(sess);
    REQUIRE(rnt_session_set_branch(sid.c_str(), "test_step5_override", s1.c_str()) == 0);

    // Advance the branch to S2 — global HEAD moves on; the session override
    // keeps S1 resident.
    REQUIRE(rnt_link_tuple(rpath, "id=2\n", &th) == 0);
    rnt_free_string(th);

    // Session view: still S1 (one tuple).
    const std::string spath = "/system/sessions/" + sid +
                              "/branches/test_step5_override/multigroups/public/relations/items";

    rnt_handle_t h_session = rnt_open_handle(spath.c_str(), nullptr);
    REQUIRE(h_session != nullptr);
    rnt_cursor_t c_session = rnt_cursor_open(h_session);
    REQUIRE(c_session != nullptr);

    int rows_under_session = 0;
    char* row = nullptr;
    while (rnt_cursor_next(c_session, &row) == 1) {
        ++rows_under_session;
        rnt_free_string(row);
    }
    REQUIRE(rows_under_session == 1);

    rnt_cursor_close(c_session);
    rnt_close_handle(h_session);

    // Global view sees both tuples.
    rnt_handle_t h_global = rnt_open_handle(rpath, nullptr);
    REQUIRE(h_global != nullptr);
    rnt_cursor_t c_global = rnt_cursor_open(h_global);
    REQUIRE(c_global != nullptr);
    int rows_global = 0;
    while (rnt_cursor_next(c_global, &row) == 1) {
        ++rows_global;
        rnt_free_string(row);
    }
    REQUIRE(rows_global == 2);
    rnt_cursor_close(c_global);
    rnt_close_handle(h_global);

    REQUIRE(rnt_session_close(sid.c_str()) == 0);
}

TEST_CASE("Clearing a session override falls back to the global branch HEAD",
          "[step5][capi][session][resolver]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_step5_clear";
    const char* rpath = "/system/branches/test_step5_clear/multigroups/public/relations/items";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    char* th = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &th) == 0);
    rnt_free_string(th);
    rnt_handle_t bh = rnt_open_handle(bpath, nullptr);
    REQUIRE(bh != nullptr);
    char* target = nullptr;
    REQUIRE(rnt_branch_target(bh, &target) == 0);
    const std::string s1 = take_string(target);
    rnt_close_handle(bh);

    // Same pattern as above: install the override on S1 before advancing.
    char* sess = nullptr;
    REQUIRE(rnt_session_open(nullptr, &sess) == 0);
    const std::string sid = take_string(sess);
    REQUIRE(rnt_session_set_branch(sid.c_str(), "test_step5_clear", s1.c_str()) == 0);

    REQUIRE(rnt_link_tuple(rpath, "id=2\n", &th) == 0);
    rnt_free_string(th);

    // Clear the override.
    REQUIRE(rnt_session_set_branch(sid.c_str(), "test_step5_clear", "") == 0);

    // Now the session sees the global view (two tuples).
    const std::string spath =
        "/system/sessions/" + sid + "/branches/test_step5_clear/multigroups/public/relations/items";
    rnt_handle_t h = rnt_open_handle(spath.c_str(), nullptr);
    REQUIRE(h != nullptr);
    rnt_cursor_t c = rnt_cursor_open(h);
    REQUIRE(c != nullptr);
    int rows = 0;
    char* row = nullptr;
    while (rnt_cursor_next(c, &row) == 1) {
        ++rows;
        rnt_free_string(row);
    }
    REQUIRE(rows == 2);
    rnt_cursor_close(c);
    rnt_close_handle(h);

    REQUIRE(rnt_session_close(sid.c_str()) == 0);
}

TEST_CASE("rnt_session_set_branch rejects an unregistered snapshot", "[step5][capi][session]") {
    InitGuard _;
    char* sess = nullptr;
    REQUIRE(rnt_session_open(nullptr, &sess) == 0);
    const std::string sid = take_string(sess);

    REQUIRE(rnt_session_set_branch(
                sid.c_str(), "anything",
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != 0);

    REQUIRE(rnt_session_close(sid.c_str()) == 0);
}

// ---------------------------------------------------------------------------
// Multi-mg-per-branch — sibling multigroups under one branch evolve
// independently. Inserting into one mg must not perturb the other's hash
// or its enumerable relation set.
// ---------------------------------------------------------------------------

TEST_CASE("Two multigroups under one branch advance independently", "[capi][multi-mg]") {
    InitGuard _;
    const std::string bpath = "/system/branches/test_multi_mg";
    REQUIRE(rnt_register_branch(bpath.c_str(), "") == 0);

    // Register one relation in each of two distinct multigroups.
    REQUIRE(rnt_register_relation((bpath + "/multigroups/warehouse/relations/orders").c_str()) ==
            0);
    REQUIRE(rnt_register_relation((bpath + "/multigroups/audit/relations/events").c_str()) == 0);

    char* mgs_raw = nullptr;
    REQUIRE(rnt_list_branch_multigroups(bpath.c_str(), &mgs_raw) == 0);
    const std::string mgs = take_string(mgs_raw);
    REQUIRE(mgs.find("warehouse\t") != std::string::npos);
    REQUIRE(mgs.find("audit\t") != std::string::npos);

    // Insert into warehouse; record audit's root before/after.
    char* audit_before = nullptr;
    REQUIRE(rnt_list_relations((bpath + "/multigroups/audit").c_str(), &audit_before) == 0);
    const std::string audit_before_s = take_string(audit_before);

    char* th = nullptr;
    REQUIRE(rnt_link_tuple((bpath + "/multigroups/warehouse/relations/orders").c_str(), "id=1\n",
                           &th) == 0);
    rnt_free_string(th);

    char* audit_after = nullptr;
    REQUIRE(rnt_list_relations((bpath + "/multigroups/audit").c_str(), &audit_after) == 0);
    const std::string audit_after_s = take_string(audit_after);

    // audit's relation set is byte-identical: the warehouse-side mutation
    // touched only the warehouse subtree at the multigroup level.
    REQUIRE(audit_before_s == audit_after_s);

    // warehouse/orders is now non-empty.
    char* root = nullptr;
    REQUIRE(rnt_relation_root((bpath + "/multigroups/warehouse/relations/orders").c_str(), &root) ==
            0);
    REQUIRE(!take_string(root).empty());

    // audit/events still empty.
    char* root2 = nullptr;
    REQUIRE(rnt_relation_root((bpath + "/multigroups/audit/relations/events").c_str(), &root2) ==
            0);
    REQUIRE(take_string(root2).empty());
}

TEST_CASE("Constraint register / body / reverse-query / drop round-trip", "[capi][constraint]") {
    InitGuard _;
    const char* owner = "/system/branches/test_constraint_admin";
    REQUIRE(rnt_register_branch(owner, "") == 0);

    // Two attribute-scoped edges: an Employee FK is violated by an INSERT into
    // Employee and by a DELETE from Department.
    const char* body = "(MemberOf (target Department) (binding ((dept_id (Var dept_id)))))";
    const char* edges = "insert\tEmployee\tdept_id\ndelete\tDepartment\tdept_id\n";

    char* path_raw = nullptr;
    REQUIRE(rnt_register_constraint(owner, "fk_emp_dept", body, edges, &path_raw) == 0);
    const std::string path = take_string(path_raw);
    REQUIRE(path == "system/branches/test_constraint_admin/constraints/fk_emp_dept");

    // Body round trips verbatim
    char* body_raw = nullptr;
    REQUIRE(rnt_constraint_body(path.c_str(), &body_raw) == 0);
    REQUIRE(take_string(body_raw) == body);

    // Reverse query matches the two triggering mutations, nothing else
    char* q = nullptr;
    REQUIRE(rnt_constraints_for("Employee", "insert", &q) == 0);
    REQUIRE(take_string(q).find(path) != std::string::npos);
    REQUIRE(rnt_constraints_for("Department", "delete", &q) == 0);
    REQUIRE(take_string(q).find(path) != std::string::npos);
    // Non-triggering pairs: no match.
    REQUIRE(rnt_constraints_for("Department", "insert", &q) == 0);
    REQUIRE(take_string(q).empty());
    REQUIRE(rnt_constraints_for("Employee", "delete", &q) == 0);
    REQUIRE(take_string(q).empty());

    // Drop removes the object: the body is gone, the reverse query is empty, and
    // a second drop fails
    REQUIRE(rnt_drop_constraint(owner, "fk_emp_dept") == 0);
    REQUIRE(rnt_constraint_body(path.c_str(), &body_raw) != 0);
    REQUIRE(rnt_constraints_for("Employee", "insert", &q) == 0);
    REQUIRE(take_string(q).empty());
    REQUIRE(rnt_drop_constraint(owner, "fk_emp_dept") != 0);
}

TEST_CASE("rnt_constraint_check reports satisfied and violated from a denial plan",
          "[capi][constraint]") {
    InitGuard _;
    const char* bpath = "/system/branches/test_constraint_check";
    const char* rpath = "/system/branches/test_constraint_check/multigroups/public/relations/viol";
    REQUIRE(rnt_register_branch(bpath, "") == 0);
    REQUIRE(rnt_register_relation(rpath) == 0);

    char* th = nullptr;
    REQUIRE(rnt_link_tuple(rpath, "id=1\n", &th) == 0);
    rnt_free_string(th);

    // Satisfied: a denial that yields nothing. Take 0 over the scan is the
    // empty violation set, so the verdict is "satisfied" with no witness.
    {
        PlanAction scan{};
        scan.operation = nt::FOL_OPERATION_SCAN;
        scan.scan.relation_path = rpath;
        rnt_plan_t inner = rnt_plan_assemble(scan);
        REQUIRE(inner != nullptr);

        PlanAction take{};
        take.operation = nt::FOL_OPERATION_TAKE;
        take.take.source = inner;
        take.take.limit = 0;
        rnt_plan_t plan = rnt_plan_assemble(take);
        REQUIRE(plan != nullptr);

        int verdict = -1;
        char* witness = nullptr;
        REQUIRE(rnt_constraint_check(plan, &verdict, &witness) == 0);
        REQUIRE(verdict == 0);
        REQUIRE(witness == nullptr);
    }

    // Violated: the scan yields the offending tuple, so the verdict is
    // "violated" and the first row is returned as the witness.
    {
        PlanAction scan{};
        scan.operation = nt::FOL_OPERATION_SCAN;
        scan.scan.relation_path = rpath;
        rnt_plan_t plan = rnt_plan_assemble(scan);
        REQUIRE(plan != nullptr);

        int verdict = -1;
        char* witness = nullptr;
        REQUIRE(rnt_constraint_check(plan, &verdict, &witness) == 0);
        REQUIRE(verdict == 1);
        REQUIRE(witness != nullptr);
        REQUIRE(take_string(witness).find("id=1") != std::string::npos);
    }
}

TEST_CASE("rnt_register_constraint validates owner, name, and edges", "[capi][constraint]") {
    InitGuard _;

    // Owner must exist.
    REQUIRE(rnt_register_constraint("/system/branches/no_such_owner_xyz", "c", "body", "", nullptr) !=
            0);

    const char* owner = "/system/branches/test_constraint_validate";
    REQUIRE(rnt_register_branch(owner, "") == 0);

    // A name with '/' would not round-trip (it splits into extra path segments).
    REQUIRE(rnt_register_constraint(owner, "a/b", "body", "", nullptr) != 0);

    // Malformed edges: a line with only an operation, and a line with an empty
    // relation, are both rejected.
    REQUIRE(rnt_register_constraint(owner, "c", "body", "insert\n", nullptr) != 0);
    REQUIRE(rnt_register_constraint(owner, "c", "body", "insert\t\tdept_id\n", nullptr) != 0);

    // Empty edges are valid: a constraint no mutation triggers.
    REQUIRE(rnt_register_constraint(owner, "c", "body", "", nullptr) == 0);

    // Re-registering replaces the body and the constraint is still droppable
    // exactly once (the owner pin is not double-counted across a replace).
    REQUIRE(rnt_register_constraint(owner, "c", "body2", "", nullptr) == 0);
    char* b = nullptr;
    REQUIRE(rnt_constraint_body("system/branches/test_constraint_validate/constraints/c", &b) == 0);
    REQUIRE(take_string(b) == "body2");
    REQUIRE(rnt_drop_constraint(owner, "c") == 0);
    REQUIRE(rnt_drop_constraint(owner, "c") != 0);
}
