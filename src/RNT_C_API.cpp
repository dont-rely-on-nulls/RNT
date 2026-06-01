#include "RNT_C_API.h"

#include "CursorManager.h"
#include "HandlerManager.h"
#include "IdentityManager.h"
#include "LifecycleManager.h"
#include "Merkle.h"
#include "MultigroupCodec.h"
#include "NamespaceReferenceManager.h"
#include "ObjectManager.h"
#include "PermissionsManager.h"
#include "InMemoryBackend.h"
#include "SqliteBackend.h"
#include "TupleCodec.h"
#include "VM.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Global runtime state
//
// A single Runtime instance is created per process on the first successful
// rnt_init call.  All managers share this instance; they do not hold their
// own state.  Initialisation is protected by g_init_mutex so that concurrent
// first-callers are safe; once g_init_done is true the mutex is never
// contended again.
// ---------------------------------------------------------------------------

namespace
{
    struct Runtime
    {
        std::unique_ptr<nt::IStorageBackend> storage;
        nt::ObjectManager      objects;
        nt::PermissionsManager permissions;
        nt::IdentityManager    identities;
        std::unique_ptr<nt::LifecycleManager> lifecycles;
        std::unique_ptr<nt::NamespaceReferenceManager> references;
        std::unique_ptr<nt::HandlerManager> handler;
        std::unique_ptr<nt::CursorManager>  cursors;
    };

    static std::unique_ptr<Runtime> g_rt;
    static bool                     g_init_done = false;

    bool is_initialized() { return g_init_done; }

    static std::vector<std::string> split_path(const char* path)
    {
        std::vector<std::string> parts;
        if (!path) return parts;
        std::string s(path);
        if (!s.empty() && s[0] == '/') s.erase(0, 1);
        std::stringstream ss(s);
        std::string part;
        while (std::getline(ss, part, '/'))
            if (!part.empty()) parts.push_back(part);
        return parts;
    }

    static std::vector<nt::Attribute> parse_kv(const char* kv)
    {
        std::vector<nt::Attribute> attrs;
        if (!kv) return attrs;
        std::stringstream ss(kv);
        std::string line;
        while (std::getline(ss, line))
        {
            if (line.empty()) continue;
            const auto pos = line.find('=');
            if (pos == std::string::npos) continue;
            attrs.push_back({ line.substr(0, pos), line.substr(pos + 1) });
        }
        return attrs;
    }

    static std::string tuple_to_kv(nt::Tuple* t)
    {
        std::string out;
        t->Reset();
        const nt::Attribute* a = t->Next();
        while (a)
        {
            out += a->name + "=" + a->value + "\n";
            a = t->Next();
        }
        return out;
    }

    static char* heap_str(const std::string& s)
    {
        char* p = new char[s.size() + 1];
        std::memcpy(p, s.data(), s.size());
        p[s.size()] = '\0';
        return p;
    }

    static std::unique_ptr<nt::ObjectManager::object_type> make_relation_type()
    {
        auto t      = std::make_unique<nt::ObjectManager::object_type>();
        t->label    = RELATION;
        t->disposable = false;
        t->methods  = { OPEN, CLOSE };
        t->exclusive = false;
        return t;
    }

    static std::unique_ptr<nt::ObjectManager::object_type> make_branch_type()
    {
        auto t      = std::make_unique<nt::ObjectManager::object_type>();
        t->label    = BRANCH;
        t->disposable = false;
        t->methods  = { OPEN, CLOSE };
        // Branches are mutable reference heads: serialize writers through
        // LifecycleManager::Contention.
        t->exclusive = true;
        return t;
    }

    static std::unique_ptr<nt::ObjectManager::object_type> make_multigroup_type()
    {
        auto t      = std::make_unique<nt::ObjectManager::object_type>();
        t->label    = MULTIGROUP;
        t->disposable = false;
        t->methods  = { OPEN, CLOSE };
        // Multigroup snapshots are immutable and content-addressed; concurrent
        // readers never contend. GC is gated by reference_count only.
        t->exclusive = false;
        return t;
    }

    static std::unique_ptr<nt::ObjectManager::object_type> make_branch_tree_type()
    {
        auto t      = std::make_unique<nt::ObjectManager::object_type>();
        t->label    = BRANCH_TREE;
        t->disposable = false;
        t->methods  = { OPEN, CLOSE };
        // Branch-tree blobs are immutable content-addressed merkle roots;
        // GC is gated by reference_count only.
        t->exclusive = false;
        return t;
    }

    static std::unique_ptr<nt::ObjectManager::object_type> make_session_type()
    {
        auto t      = std::make_unique<nt::ObjectManager::object_type>();
        t->label    = SESSION;
        // Sessions live only as long as their connection; rnt_session_close
        // removes them via ObjectManager::Unregister.
        t->disposable = true;
        t->methods  = { OPEN, CLOSE };
        // Multiple readers/writers may consult a session concurrently to read
        // overrides; contention is only enforced when an exclusive mutator
        // (set_branch) is wired up. Default to non-exclusive for now.
        t->exclusive = false;
        return t;
    }

    // Generates a random 256-bit hex hash for naming a session. Hashes are
    // drawn from std::random_device-seeded mt19937_64; we do not need
    // cryptographic strength here, just enough entropy that two concurrent
    // rnt_session_open calls cannot collide.
    static std::string random_session_hash()
    {
        static thread_local std::mt19937_64 rng{ std::random_device{}() };
        static const char hex[] = "0123456789abcdef";

        std::string out;
        out.reserve(64);
        for (int i = 0; i < 4; ++i)
        {
            uint64_t v = rng();
            for (int b = 0; b < 8; ++b)
            {
                uint8_t byte = static_cast<uint8_t>(v & 0xFF);
                out.push_back(hex[(byte >> 4) & 0xF]);
                out.push_back(hex[byte & 0xF]);
                v >>= 8;
            }
        }
        return out;
    }

    // Serializes the (name, merkle_root) pairs into the storage backend and
    // registers the resulting multigroup snapshot under /system/snapshots/<hash>,
    // with one Relation entry per child at /system/snapshots/<hash>/<name>.
    // Idempotent: if the snapshot already exists in the registry the existing
    // entries are reused. Returns the multigroup hash, or empty string on error.
    //
    // Each child Relation is Pinned by its parent Multigroup at creation time.
    // LifecycleManager::CascadeMultigroup releases these pins when the
    // multigroup itself becomes GC-eligible.
    static std::string register_snapshot(
        const std::vector<nt::MultigroupCodec::RelationEntry>& relations)
    {
        if (!g_rt) return {};

        const std::string hash = nt::MultigroupCodec::Build(*g_rt->storage, relations);
        if (hash.empty()) return {};
        const auto snap_path = split_path(("/system/snapshots/" + hash).c_str());

        if (g_rt->objects.Find(snap_path) != nullptr) return hash;

        auto mg = std::make_unique<nt::ObjectManager::Multigroup>();
        mg->merkle_root = hash;
        g_rt->objects.Register(snap_path, std::move(mg), make_multigroup_type());

        for (const auto& [name, root] : relations)
        {
            const auto rel_path = split_path(
                ("/system/snapshots/" + hash + "/relations/" + name).c_str());
            if (g_rt->objects.Find(rel_path) != nullptr) continue;

            auto rel = std::make_unique<nt::ObjectManager::Relation>();
            rel->merkle_root = root;
            g_rt->objects.Register(rel_path, std::move(rel), make_relation_type());

            // Structural pin from the parent Multigroup; released by
            // LifecycleManager::CascadeMultigroup at GC time.
            g_rt->lifecycles->Pin(g_rt->objects.Find(rel_path));
        }
        return hash;
    }

    // Enumerates (mg_name, mg_hash) pairs in a branch-tree.
    static std::vector<std::pair<std::string, std::string>>
    list_branch_tree(const std::string& branch_tree_root)
    {
        std::vector<std::pair<std::string, std::string>> out;
        if (branch_tree_root.empty()) return out;
        constexpr size_t kPageSize = 1024;
        size_t offset = 0;
        while (true)
        {
            auto page = nt::Merkle<std::string>::Page(*g_rt->storage,
                                                      branch_tree_root,
                                                      offset, kPageSize);
            if (page.empty()) break;
            for (auto& entry : page)
                out.emplace_back(std::move(entry.key),
                                  nt::bin_to_hex(entry.payload));
            if (page.size() < kPageSize) break;
            offset += page.size();
        }
        return out;
    }

    // Registers /system/branch_trees/<hash> as a BRANCH_TREE if missing, and
    // takes one structural pin on each multigroup the tree references. The
    // pins are mirrored by LifecycleManager::CascadeBranchTree at GC time.
    // Idempotent: a second call with the same hash returns immediately.
    static void register_branch_tree(const std::string& tree_root)
    {
        if (tree_root.empty()) return;
        const auto bt_path = split_path(
            ("/system/branch_trees/" + tree_root).c_str());
        if (g_rt->objects.Find(bt_path) != nullptr) return;

        auto bt = std::make_unique<nt::ObjectManager::BranchTree>();
        bt->merkle_root = tree_root;
        g_rt->objects.Register(bt_path, std::move(bt), make_branch_tree_type());

        for (const auto& [_, mg_hash] : list_branch_tree(tree_root))
        {
            if (mg_hash.empty()) continue;
            const auto p = split_path(("/system/snapshots/" + mg_hash).c_str());
            g_rt->lifecycles->Pin(g_rt->objects.Find(p));
        }
    }

    // Adjusts pins when a branch (or session override) moves its bound
    // branch-tree root. The new tree is pinned before the old is unpinned so
    // a no-op advance never sees a pinned BranchTree's ref_count briefly hit
    // zero and trigger cascade collection of every mg it references.
    static void rebind_branch_tree_pin(const std::string& old_tree_root,
                                        const std::string& new_tree_root)
    {
        if (old_tree_root == new_tree_root) return;
        if (!new_tree_root.empty())
        {
            register_branch_tree(new_tree_root);
            const auto p = split_path(
                ("/system/branch_trees/" + new_tree_root).c_str());
            g_rt->lifecycles->Pin(g_rt->objects.Find(p));
        }
        if (!old_tree_root.empty())
        {
            const auto p = split_path(
                ("/system/branch_trees/" + old_tree_root).c_str());
            g_rt->lifecycles->Unpin(g_rt->objects.Find(p));
        }
    }

    // Looks up the mg_hash currently bound to `mg_name` in the branch's tree.
    // Returns empty string when the branch is unborn or the mg is absent.
    static std::string lookup_branch_mg(const nt::ObjectManager::Branch& branch,
                                         const std::string& mg_name)
    {
        if (branch.target_hash.empty()) return "";
        auto found = nt::Merkle<std::string>::Get(*g_rt->storage,
                                                   branch.target_hash, mg_name);
        if (!found) return "";
        static const nt::Hash32 zero{};
        if (*found == zero) return "";
        return nt::bin_to_hex(*found);
    }

    // Reads the (relation_name, root) list of a specific multigroup under a
    // branch. Returns empty for unborn branches or absent multigroups.
    static std::vector<nt::MultigroupCodec::RelationEntry> read_mg_relations(
        const nt::ObjectManager::Branch& branch,
        const std::string& mg_name)
    {
        const std::string mg_hash = lookup_branch_mg(branch, mg_name);
        if (mg_hash.empty()) return {};
        return nt::MultigroupCodec::List(*g_rt->storage, mg_hash);
    }

    // Looks up a branch object by path. Returns nullptr when the path does not
    // resolve to a BRANCH.
    static nt::ObjectManager::Branch* find_branch(
        const std::vector<std::string>& branch_path)
    {
        auto* entry = g_rt->objects.Find(branch_path);
        if (!entry || !entry->object || !entry->head) return nullptr;
        if (entry->head->type->label != BRANCH) return nullptr;
        return dynamic_cast<nt::ObjectManager::Branch*>(entry->object.get());
    }

    // Parses a path of the form
    //   /system/branches/<name>/multigroups/<mg>/relations/<rel>.
    // Returns true on success; out-parameters are populated with the branch
    // path, the multigroup name, and the relation name. Returns false for
    // any other path shape.
    static bool split_branch_mg_relation(const std::vector<std::string>& parts,
                                          std::vector<std::string>& branch_path_out,
                                          std::string& mg_name_out,
                                          std::string& relation_name_out)
    {
        if (parts.size() != 7) return false;
        if (parts[0] != "system"      || parts[1] != "branches"
         || parts[3] != "multigroups" || parts[5] != "relations") return false;
        branch_path_out   = { "system", "branches", parts[2] };
        mg_name_out       = parts[4];
        relation_name_out = parts[6];
        return true;
    }

    // Applies a per-relation root update with the full two-level cascade:
    //   1. Read the (rel, root) list of `mg_name` from the branch's current
    //      tree (or empty when the mg is absent / branch is unborn).
    //   2. Insert/replace (relation_name, new_root) in that list.
    //   3. register_snapshot → new_mg_hash.
    //   4. Insert (mg_name → new_mg_hash) into the branch tree → new branch
    //      tree root.
    //   5. Advance branch.target_hash to the new root and rebind pins.
    // Returns the new branch tree root on success; empty on error.
    //
    // Pin/unpin transitions are applied via rebind_branch_tree_pin: new mgs
    // are pinned before old mgs are unpinned, so an unchanged advance never
    // briefly drops a multigroup's ref_count to zero.
    static std::string commit_relation_update(
        nt::ObjectManager::Branch& branch,
        const std::string& mg_name,
        const std::string& relation_name,
        const std::string& new_root)
    {
        auto relations = read_mg_relations(branch, mg_name);
        auto it = std::find_if(relations.begin(), relations.end(),
                               [&](const auto& e) { return e.first == relation_name; });
        if (it != relations.end()) it->second = new_root;
        else relations.emplace_back(relation_name, new_root);

        const std::string new_mg_hash = register_snapshot(relations);
        if (new_mg_hash.empty()) return {};

        const nt::Hash32 mg_payload = nt::hex_to_bin(new_mg_hash);
        const std::string new_tree_root = nt::Merkle<std::string>::Insert(
            *g_rt->storage, branch.target_hash, mg_name, mg_payload);

        const std::string old_tree_root = branch.target_hash;
        branch.target_hash = new_tree_root;
        rebind_branch_tree_pin(old_tree_root, new_tree_root);
        return new_tree_root;
    }

    // Returns the merkle_root of a named relation in the specified mg under
    // the branch's current tree. Empty when the branch is unborn, the mg
    // doesn't exist, or the relation is absent.
    static std::string read_relation_root(const nt::ObjectManager::Branch& branch,
                                          const std::string& mg_name,
                                          const std::string& relation_name)
    {
        const auto relations = read_mg_relations(branch, mg_name);
        auto it = std::find_if(relations.begin(), relations.end(),
                               [&](const auto& e) { return e.first == relation_name; });
        return (it == relations.end()) ? std::string{} : it->second;
    }

    // -----------------------------------------------------------------------
    // Plan builder internals
    // -----------------------------------------------------------------------

    /**
     * Wraps an entire plan subtree.  All PlanNode allocations and all
     * CursorManager::cursor* / HandlerManager::handle* opened by SCAN nodes
     * are collected here so they can be released atomically when the plan is
     * freed or transferred to a VmCursor.
     */
    struct PlanWrapper
    {
        nt::PlanNode*                                root     = nullptr;
        std::vector<std::unique_ptr<nt::PlanNode>>   nodes;    // owns every node in subtree
        std::vector<nt::CursorManager::cursor*>      cursors;  // one per SCAN leaf
        std::vector<nt::HandlerManager::handle*>     handles;  // one per SCAN leaf
    };

    static void free_plan_wrapper(PlanWrapper* pw)
    {
        if (!pw) return;
        for (auto* c : pw->cursors)  g_rt->cursors->Close(c);
        for (auto* h : pw->handles)  g_rt->handler->Close(h);
        delete pw;
    }

    /**
     * A VM cursor owns the materialised plan tree and all resources opened
     * during plan construction.  After rnt_vm_execute_plan the caller drives
     * it with rnt_vm_cursor_next / rnt_vm_cursor_close.
     */
    struct VmCursor
    {
        nt::VM                                       vm;
        nt::PlanNode*                                root;
        std::vector<std::unique_ptr<nt::PlanNode>>   nodes;
        std::vector<nt::CursorManager::cursor*>      cursors;
        std::vector<nt::HandlerManager::handle*>     handles;

        explicit VmCursor(nt::CursorManager& cm, PlanWrapper* pw)
            : vm(cm), root(pw->root)
        {
            nodes   = std::move(pw->nodes);
            cursors = std::move(pw->cursors);
            handles = std::move(pw->handles);
            delete pw;  // struct itself; resources transferred above
        }

        ~VmCursor()
        {
            for (auto* c : cursors) g_rt->cursors->Close(c);
            for (auto* h : handles) g_rt->handler->Close(h);
        }
    };

    // ---- Plan builders --------------------------------------------------
    // Pure construction: each builder receives only its operator's context and
    // assumes the runtime is already initialised. rnt_plan_assemble is the sole
    // caller and performs that check once before dispatching here.

    PlanWrapper* build_scan(const PlanArgsScan& a)
    {
        if (!a.relation_path) return nullptr;

        // Open a handle to the stored relation through the full manager pipeline.
        // Open() runs NamespaceReferenceManager::Resolve internally, so the handle
        // lands on the resolved /system/snapshots/<hash>/relations/<n> entry when
        // the caller passed a branch-relative path.
        const auto parts = split_path(a.relation_path);
        auto* h = g_rt->handler->Open(parts, nullptr);
        if (!h) return nullptr;

        // Read the Merkle root straight from the handle's object — Resolve has
        // already pointed it at the snapshot-bound Relation entry.
        std::string merkle_root;
        if (h->object && h->object->object)
        {
            auto* rel = dynamic_cast<nt::ObjectManager::Relation*>(h->object->object.get());
            if (rel) merkle_root = rel->merkle_root;
        }

        auto* c = g_rt->cursors->Open(h, merkle_root);
        if (!c)
        {
            g_rt->handler->Close(h);
            return nullptr;
        }

        auto  node        = std::make_unique<nt::PlanNode>();
        node->op          = nt::FOL_OPERATION_SCAN;
        node->scan_cursor = c;

        auto* pw = new PlanWrapper();
        pw->root = node.get();
        pw->nodes.push_back(std::move(node));
        pw->cursors.push_back(c);
        pw->handles.push_back(h);
        return pw;
    }

    PlanWrapper* build_join(const PlanArgsJoin& a)
    {
        auto* l = static_cast<PlanWrapper*>(a.left);
        auto* r = static_cast<PlanWrapper*>(a.right);

        if (!l || !r)
        {
            free_plan_wrapper(l);
            free_plan_wrapper(r);
            return nullptr;
        }

        auto  node  = std::make_unique<nt::PlanNode>();
        node->op    = nt::FOL_OPERATION_JOIN;
        node->left  = l->root;
        node->right = r->root;

        auto* pw = new PlanWrapper();
        pw->root = node.get();
        pw->nodes.push_back(std::move(node));

        // Absorb child resources into the new wrapper.
        for (auto& n : l->nodes)   pw->nodes.push_back(std::move(n));
        for (auto& n : r->nodes)   pw->nodes.push_back(std::move(n));
        for (auto* c : l->cursors) pw->cursors.push_back(c);
        for (auto* c : r->cursors) pw->cursors.push_back(c);
        for (auto* h : l->handles) pw->handles.push_back(h);
        for (auto* h : r->handles) pw->handles.push_back(h);

        delete l;
        delete r;
        return pw;
    }

    PlanWrapper* build_take(const PlanArgsTake& a)
    {
        auto* s = static_cast<PlanWrapper*>(a.source);
        if (!s) return nullptr;

        auto  node       = std::make_unique<nt::PlanNode>();
        node->op         = nt::FOL_OPERATION_TAKE;
        node->left       = s->root;
        node->take_limit = a.limit;

        auto* pw = new PlanWrapper();
        pw->root = node.get();
        pw->nodes.push_back(std::move(node));

        for (auto& n : s->nodes)   pw->nodes.push_back(std::move(n));
        for (auto* c : s->cursors) pw->cursors.push_back(c);
        for (auto* h : s->handles) pw->handles.push_back(h);

        delete s;
        return pw;
    }

    PlanWrapper* build_project(const PlanArgsProject& a)
    {
        auto* s = static_cast<PlanWrapper*>(a.source);
        if (!s) return nullptr;

        auto  node = std::make_unique<nt::PlanNode>();
        node->op   = nt::FOL_OPERATION_PROJECT;
        node->left = s->root;

        if (a.attrs)
            for (const char** p = a.attrs; *p; ++p)
                node->project_attrs.emplace(*p);

        auto* pw = new PlanWrapper();
        pw->root = node.get();
        pw->nodes.push_back(std::move(node));
        for (auto& n : s->nodes)   pw->nodes.push_back(std::move(n));
        for (auto* c : s->cursors) pw->cursors.push_back(c);
        for (auto* h : s->handles) pw->handles.push_back(h);

        delete s;
        return pw;
    }
}

// ---------------------------------------------------------------------------
// Public C API
//
// Section order mirrors the NT open-handle pipeline:
//   Runtime lifecycle → Authentication → Handle lifecycle →
//   Object registration → Tuple storage → Cursor / VM plan builder
// ---------------------------------------------------------------------------

int rnt_init(const char* driver, const char* storage_path)
{
    try
    {
        auto rt = std::make_unique<Runtime>();

        const std::string drv = driver ? driver : "sqlite";
        if (drv == "memory")
            rt->storage = std::make_unique<nt::InMemoryBackend>();
        else
            rt->storage = std::make_unique<nt::SqliteBackend>(
                storage_path ? storage_path : ":memory:");

        rt->lifecycles = std::make_unique<nt::LifecycleManager>(
            rt->objects, *rt->storage);
        rt->references = std::make_unique<nt::NamespaceReferenceManager>(
            rt->objects, *rt->storage);
        rt->handler = std::make_unique<nt::HandlerManager>(
            rt->objects, rt->permissions, rt->identities, *rt->lifecycles,
            *rt->references);
        rt->cursors = std::make_unique<nt::CursorManager>(
            *rt->storage, rt->lifecycles.get(), &rt->objects);
        g_rt = std::move(rt);

        // Register the default branch on first boot so that
        // rnt_open_handle("/system/branches/master") always succeeds.
        const auto master_path = split_path("/system/branches/master");
        if (g_rt->objects.Find(master_path) == nullptr)
        {
            auto branch  = std::make_unique<nt::ObjectManager::Branch>();
            branch->name = "master";
            g_rt->objects.Register(master_path, std::move(branch),
                                   make_branch_type());
        }

        g_init_done = true;
        return 0;
    }
    catch (...)
    {
        g_rt.reset();
        return -1;
    }
}

int rnt_firewall(const char* /*auth_method*/, char** claims_out)
{
    if (!is_initialized() || !claims_out) return -1;
    // PermissionsManager::Firewall is stubbed; grant all claims for now.
    *claims_out = heap_str("READ WRITE");
    return 0;
}

int rnt_session_open(void* connection_context, char** session_hash_out)
{
    if (!is_initialized() || !session_hash_out) return -1;

    // Retry on the astronomically unlikely event of a hash collision against
    // an already-registered session.
    std::string hash;
    for (int attempts = 0; attempts < 8; ++attempts)
    {
        hash = random_session_hash();
        const auto session_path = split_path(("/system/sessions/" + hash).c_str());
        if (g_rt->objects.Find(session_path) != nullptr) continue;

        auto session = std::make_unique<nt::ObjectManager::Session>();
        session->connection_context = connection_context;
        g_rt->objects.Register(session_path, std::move(session), make_session_type());
        *session_hash_out = heap_str(hash);
        return 0;
    }
    return -1;
}

int rnt_session_close(const char* session_hash)
{
    if (!is_initialized() || !session_hash) return -1;
    const auto session_path = split_path(
        ("/system/sessions/" + std::string(session_hash)).c_str());

    auto* entry = g_rt->objects.Find(session_path);
    if (!entry || !entry->object) return -1;
    auto* session = dynamic_cast<nt::ObjectManager::Session*>(entry->object.get());
    if (!session) return -1;

    // Release every pin this session was holding before the entry disappears,
    // so the dependent multigroups become GC-eligible.
    for (const auto& [name, hash] : session->branch_overrides)
        rebind_branch_tree_pin(hash, "");
    session->branch_overrides.clear();

    return g_rt->objects.Unregister(session_path) ? 0 : -1;
}

int rnt_session_set_branch(const char* session_hash,
                           const char* branch_name,
                           const char* target_hash)
{
    if (!is_initialized() || !session_hash || !branch_name || !target_hash)
        return -1;

    const auto session_path = split_path(
        ("/system/sessions/" + std::string(session_hash)).c_str());
    auto* entry = g_rt->objects.Find(session_path);
    if (!entry || !entry->object || !entry->head) return -1;
    if (entry->head->type->label != SESSION) return -1;

    auto* session = dynamic_cast<nt::ObjectManager::Session*>(entry->object.get());
    if (!session) return -1;

    const std::string hash(target_hash);
    std::string old_hash;
    auto it = session->branch_overrides.find(branch_name);
    if (it != session->branch_overrides.end()) old_hash = it->second;

    if (hash.empty())
    {
        session->branch_overrides.erase(branch_name);
        rebind_branch_tree_pin(old_hash, "");
        return 0;
    }

    // target_hash is a branch-tree root — a content-addressed blob produced
    // by an earlier commit. Reject if unknown.
    if (!g_rt->storage->Get(hash)) return -1;

    session->branch_overrides[branch_name] = hash;
    rebind_branch_tree_pin(old_hash, hash);
    return 0;
}

rnt_handle_t rnt_open_handle(const char* path, const char* /*claims*/)
{
    if (!is_initialized() || !path) return nullptr;
    return g_rt->handler->Open(split_path(path), nullptr);
}

int rnt_close_handle(rnt_handle_t handle)
{
    if (!is_initialized() || !handle) return -1;
    auto* h = static_cast<nt::HandlerManager::handle*>(handle);
    return g_rt->handler->Close(h) ? 0 : -1;
}

int rnt_branch_target(rnt_handle_t handle, char** target_hash_out)
{
    if (!is_initialized() || !handle || !target_hash_out) return -1;

    auto* h = static_cast<nt::HandlerManager::handle*>(handle);
    if (!h->object || !h->object->head) return -1;
    if (h->object->head->type->label != BRANCH) return -1;

    auto* branch = dynamic_cast<nt::ObjectManager::Branch*>(h->object->object.get());
    if (!branch) return -1;

    *target_hash_out = heap_str(branch->target_hash);
    return 0;
}

int rnt_branch_advance(const char* branch_path, const char* new_hash)
{
    if (!is_initialized() || !branch_path || !new_hash) return -1;

    auto* entry = g_rt->objects.Find(split_path(branch_path));
    if (!entry || !entry->object || !entry->head) return -1;
    if (entry->head->type->label != BRANCH) return -1;

    auto* branch = dynamic_cast<nt::ObjectManager::Branch*>(entry->object.get());
    if (!branch) return -1;

    const std::string hash(new_hash);
    // Non-empty branch-tree roots must already exist in the KV store. The
    // branch tree is a content-addressed blob produced by an earlier mutation
    // through commit_relation_update; advancing to an unknown root is treated
    // as a caller bug.
    if (!hash.empty() && !g_rt->storage->Get(hash)) return -1;

    const std::string old_hash = branch->target_hash;
    branch->target_hash = hash;
    rebind_branch_tree_pin(old_hash, hash);
    return 0;
}

int rnt_register_relation(const char* path)
{
    if (!is_initialized() || !path) return -1;
    const auto parts = split_path(path);

    std::vector<std::string> branch_path;
    std::string mg_name, relation_name;
    if (!split_branch_mg_relation(parts, branch_path, mg_name, relation_name))
        return -1;

    auto* branch = find_branch(branch_path);
    if (!branch) return -1;

    // Idempotent: if the relation is already present in the named mg's
    // current snapshot, the call succeeds without producing a new snapshot.
    const auto current = read_mg_relations(*branch, mg_name);
    const bool already_present = std::any_of(
        current.begin(), current.end(),
        [&](const auto& e) { return e.first == relation_name; });
    if (already_present) return 0;

    // Empty merkle_root signals a relation with no tuples.
    return commit_relation_update(*branch, mg_name, relation_name, "").empty()
        ? -1 : 0;
}

int rnt_register_branch(const char* path, const char* target_hash)
{
    if (!is_initialized() || !path) return -1;
    const auto parts = split_path(path);
    if (g_rt->objects.Find(parts) != nullptr) return 0;

    const std::string hash = target_hash ? target_hash : "";
    // Non-empty target_hash is a branch-tree root produced by an earlier
    // commit; it must already exist as a KV blob.
    if (!hash.empty() && !g_rt->storage->Get(hash)) return -1;

    auto branch         = std::make_unique<nt::ObjectManager::Branch>();
    branch->name        = parts.empty() ? "" : parts.back();
    branch->target_hash = hash;

    g_rt->objects.Register(parts, std::move(branch), make_branch_type());
    rebind_branch_tree_pin("", hash);
    return 0;
}

int rnt_list_relations(const char* branch_mg_path, char** out)
{
    if (!is_initialized() || !branch_mg_path || !out) return -1;
    const auto parts = split_path(branch_mg_path);
    if (parts.size() != 5) return -1;
    if (parts[0] != "system" || parts[1] != "branches"
     || parts[3] != "multigroups") return -1;

    auto* branch = find_branch({ "system", "branches", parts[2] });
    if (!branch) return -1;
    const auto relations = read_mg_relations(*branch, parts[4]);
    std::string result;
    for (const auto& [name, root] : relations)
        result += name + "\t" + root + "\n";
    *out = heap_str(result);
    return 0;
}

int rnt_list_branch_multigroups(const char* branch_path, char** out)
{
    if (!is_initialized() || !branch_path || !out) return -1;
    auto* branch = find_branch(split_path(branch_path));
    if (!branch) return -1;
    const auto mgs = list_branch_tree(branch->target_hash);
    std::string result;
    for (const auto& [name, mg_hash] : mgs)
        result += name + "\t" + mg_hash + "\n";
    *out = heap_str(result);
    return 0;
}

int rnt_list_snapshot_relations(const char* snapshot_hash, char** out)
{
    if (!is_initialized() || !snapshot_hash || !out) return -1;
    const std::string hash(snapshot_hash);
    const auto snap_path = split_path(("/system/snapshots/" + hash).c_str());
    auto* entry = g_rt->objects.Find(snap_path);
    if (!entry || !entry->object) return -1;
    auto* mg = dynamic_cast<nt::ObjectManager::Multigroup*>(entry->object.get());
    if (!mg) return -1;
    const auto relations = nt::MultigroupCodec::List(*g_rt->storage, mg->merkle_root);
    std::string result;
    for (const auto& [name, root] : relations)
        result += name + "\t" + root + "\n";
    *out = heap_str(result);
    return 0;
}

int rnt_link_tuple(const char* relation_path, const char* kv_attrs, char** hash_out)
{
    if (!is_initialized() || !relation_path || !kv_attrs || !hash_out) return -1;
    const auto parts = split_path(relation_path);

    std::vector<std::string> branch_path;
    std::string mg_name, relation_name;
    if (!split_branch_mg_relation(parts, branch_path, mg_name, relation_name))
        return -1;

    auto* branch = find_branch(branch_path);
    if (!branch) return -1;

    const std::string old_root = read_relation_root(*branch, mg_name, relation_name);

    auto bytes           = nt::TupleCodec::Serialize(parse_kv(kv_attrs));
    const auto tuple_hash = g_rt->storage->Put(std::move(bytes));
    const auto tuple_bin  = nt::hex_to_bin(tuple_hash);
    const std::string new_root =
        nt::Merkle<nt::Hash32>::Insert(*g_rt->storage, old_root,
                                        tuple_bin, tuple_bin);

    if (commit_relation_update(*branch, mg_name, relation_name, new_root).empty())
        return -1;

    *hash_out = heap_str(tuple_hash);
    return 0;
}

int rnt_unlink_tuple(const char* relation_path, const char* tuple_hash)
{
    if (!is_initialized() || !relation_path || !tuple_hash) return -1;
    const auto parts = split_path(relation_path);

    std::vector<std::string> branch_path;
    std::string mg_name, relation_name;
    if (!split_branch_mg_relation(parts, branch_path, mg_name, relation_name))
        return -1;

    auto* branch = find_branch(branch_path);
    if (!branch) return -1;

    const std::string old_root = read_relation_root(*branch, mg_name, relation_name);
    const std::string new_root =
        nt::Merkle<nt::Hash32>::Remove(*g_rt->storage, old_root,
                                        nt::hex_to_bin(tuple_hash));

    return commit_relation_update(*branch, mg_name, relation_name, new_root).empty()
        ? -1 : 0;
}

int rnt_clear_relation(const char* relation_path)
{
    if (!is_initialized() || !relation_path) return -1;
    const auto parts = split_path(relation_path);

    std::vector<std::string> branch_path;
    std::string mg_name, relation_name;
    if (!split_branch_mg_relation(parts, branch_path, mg_name, relation_name))
        return -1;

    auto* branch = find_branch(branch_path);
    if (!branch) return -1;

    return commit_relation_update(*branch, mg_name, relation_name, "").empty()
        ? -1 : 0;
}

int rnt_relation_root(const char* relation_path, char** root_hash_out)
{
    if (!is_initialized() || !relation_path || !root_hash_out) return -1;
    const auto parts = split_path(relation_path);

    std::vector<std::string> branch_path;
    std::string mg_name, relation_name;
    if (!split_branch_mg_relation(parts, branch_path, mg_name, relation_name))
        return -1;

    auto* branch = find_branch(branch_path);
    if (!branch) return -1;

    // Distinguish "relation registered but empty" (returns 0 with empty hash)
    // from "relation not in this multigroup's snapshot" (returns -1). Without
    // this check an unborn branch would silently report every relation empty.
    const auto relations = read_mg_relations(*branch, mg_name);
    auto it = std::find_if(relations.begin(), relations.end(),
                           [&](const auto& e) { return e.first == relation_name; });
    if (it == relations.end()) return -1;

    *root_hash_out = heap_str(it->second);
    return 0;
}

rnt_cursor_t rnt_cursor_open(rnt_handle_t handle)
{
    if (!is_initialized() || !handle) return nullptr;
    auto* h = static_cast<nt::HandlerManager::handle*>(handle);

    std::string merkle_root;
    if (h->object && h->object->head &&
        h->object->head->type->label == RELATION)
    {
        auto* rel = dynamic_cast<nt::ObjectManager::Relation*>(h->object->object.get());
        if (rel) merkle_root = rel->merkle_root;
    }

    return g_rt->cursors->Open(h, merkle_root);
}

int rnt_cursor_next(rnt_cursor_t cursor, char** tuple_out)
{
    if (!is_initialized() || !cursor || !tuple_out) return -1;
    auto* c = static_cast<nt::CursorManager::cursor*>(cursor);
    nt::Tuple* t = g_rt->cursors->Next(c);
    if (!t) { *tuple_out = nullptr; return 0; }
    *tuple_out = heap_str(tuple_to_kv(t));
    return 1;
}

int rnt_cursor_close(rnt_cursor_t cursor)
{
    if (!is_initialized() || !cursor) return -1;
    g_rt->cursors->Close(static_cast<nt::CursorManager::cursor*>(cursor));
    return 0;
}

void rnt_free_string(char* s)  { delete[] s; }
void rnt_free_bytes(uint8_t* p) { delete[] p; }

// ---------------------------------------------------------------------------
// VM plan builder
// ---------------------------------------------------------------------------

rnt_plan_t rnt_plan_assemble(PlanAction action)
{
  if (!is_initialized()) return nullptr;
  
  switch (action.operation){
  case nt::FOL_OPERATION_SCAN:    return build_scan(action.args.scan);
  case nt::FOL_OPERATION_JOIN:    return build_join(action.args.join);
  case nt::FOL_OPERATION_TAKE:    return build_take(action.args.take);
  case nt::FOL_OPERATION_PROJECT: return build_project(action.args.project);
  }
  
  return nullptr;
}

void rnt_plan_free(rnt_plan_t plan)
{
    free_plan_wrapper(static_cast<PlanWrapper*>(plan));
}

rnt_cursor_t rnt_vm_execute_plan(rnt_plan_t plan)
{
    if (!is_initialized() || !plan) return nullptr;
    // VmCursor constructor transfers ownership from PlanWrapper and deletes it.
    return new VmCursor(*g_rt->cursors, static_cast<PlanWrapper*>(plan));
}

int rnt_vm_cursor_next(rnt_cursor_t vm_cursor, char** tuple_out)
{
    if (!is_initialized() || !vm_cursor || !tuple_out) return -1;
    auto* vc = static_cast<VmCursor*>(vm_cursor);
    nt::Tuple* t = vc->vm.Next(vc->root);
    if (!t) { *tuple_out = nullptr; return 0; }
    *tuple_out = heap_str(tuple_to_kv(t));
    return 1;
}

int rnt_vm_cursor_close(rnt_cursor_t vm_cursor)
{
    if (!is_initialized() || !vm_cursor) return -1;
    // VmCursor destructor closes all cursors and handles.
    delete static_cast<VmCursor*>(vm_cursor);
    return 0;
}
