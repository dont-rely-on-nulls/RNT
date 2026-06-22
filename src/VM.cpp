#include "VM.h"
#include "Types.h"

namespace nt {
    VM::VM(CursorManager& cursors) : cursors_(cursors) {
    }

    std::vector<std::string> VM::ResolveArgs(const std::vector<PathArg>& tmpl, Tuple* from) {
        std::vector<std::string> resolved;
        resolved.reserve(tmpl.size());
        for (const auto& arg : tmpl) {
            if (arg.kind == PathArg::Kind::Const) {
                resolved.push_back(arg.name);
                continue;
            }
            std::string val;
            for (const auto& attr : from->attrs())
                if (attr.name == arg.name) {
                    val = attr.value;
                    break;
                }
            resolved.push_back(std::move(val));
        }
        return resolved;
    }

    void VM::ResetInner(CursorManager::cursor* c, std::vector<std::string> args) {
        c->args = std::move(args);
        c->page.clear();
        c->page_position = 0;
        c->fetch_offset = 0;
        c->exhausted = false;
    }

    void VM::Rewind(PlanNode* node, Tuple* outer) {
        if (node == nullptr)
            return;

        switch (node->op) {
        case Operation::FOL_OPERATION_SCAN:
            ResetInner(node->scan_cursor, ResolveArgs(node->scan_args, outer));
            break;

        case Operation::FOL_OPERATION_PROJECT:
            Rewind(node->left, outer);
            break;

        case Operation::FOL_OPERATION_TAKE:
            node->take_count = 0;
            Rewind(node->left, outer);
            break;

        case Operation::FOL_OPERATION_JOIN:
            node->join_left = nullptr;
            Rewind(node->left, outer);
            Rewind(node->right, outer);
            break;

        case Operation::FOL_OPERATION_MATERIALIZE:
            // Rewind the replay cursor only, and don't pass `outer` to the child.
            // The point of this node is to reuse the cached tuples for every
            // outer tuple, so it must not re-run or rebind what it cached.
            node->mat_pos = 0;
            break;

        case Operation::FOL_OPERATION_RENAME:
            Rewind(node->upstream, outer);
            break;

        case Operation::FOL_OPERATION_UNION:
            node->current_node = node->nodes.begin();
            for (auto& node : node->nodes)
                Rewind(node, outer);
            break;
        }
    }

    Tuple* VM::MergeInto(PlanNode* node, Tuple* left, Tuple* right) {
        std::vector<Attribute> merged;
        for (const auto& a : left->attrs())
            merged.push_back(a);
        for (const auto& a : right->attrs())
            merged.push_back(a);
        node->join_buffer.emplace(std::move(merged));
        return &*node->join_buffer;
    }

    Tuple* VM::Next(PlanNode* node) {
        if (node == nullptr)
            return nullptr;

        switch (node->op) {
        case Operation::FOL_OPERATION_SCAN:
            return cursors_.Next(node->scan_cursor);

        case Operation::FOL_OPERATION_PROJECT: {
            Tuple* next = Next(node->left);
            if (next == nullptr)
                return nullptr;

            std::vector<Attribute> projected;
            for (const auto& attr : next->attrs()) {
                if (node->project_attrs.find(attr.name) != node->project_attrs.end())
                    projected.push_back(attr);
            }

            node->project_buffer.emplace(std::move(projected));
            return &*node->project_buffer;
        }

        case Operation::FOL_OPERATION_JOIN: {
            while (true) {
            again:
                if (node->join_left == nullptr) {
                    node->join_left = Next(node->left);
                    if (node->join_left == nullptr) return nullptr;

                    Rewind(node->right, node->join_left);
                }

                Tuple* right = Next(node->right);
                if (right != nullptr) {
                    for (auto &attr : node->join_attrs)
                        if ((*node->join_left)[attr] != (*right)[attr])
                            goto again;

                    return MergeInto(node, node->join_left, right);
                }

                node->join_left = nullptr;
            }
        }

        case Operation::FOL_OPERATION_TAKE: {
            if (node->take_count >= node->take_limit)
                return nullptr;
            Tuple* t = Next(node->left);
            if (t)
                ++node->take_count;
            return t;
        }

        case Operation::FOL_OPERATION_MATERIALIZE: {
            if (!node->mat_done) {
                // First scan: pull a tuple and keep our own copy. We rebuild it
                // from attrs() rather than copying the Tuple, because a Tuple
                // holds an iterator into its own map and a plain copy would leave
                // that iterator dangling. The child also overwrites its output
                // buffer on the next pull, so we cannot just keep its pointer.
                Tuple* t = Next(node->left);
                if (t != nullptr) {
                    std::vector<Attribute> attrs;
                    for (const auto& a : t->attrs())
                        attrs.push_back(a);
                    node->mat_buffer.emplace_back(std::move(attrs));
                    return &node->mat_buffer.back();
                }
                node->mat_done = true;
                return nullptr; // child exhausted; do not fall into replay
            }

            // Later scans: hand back cached tuples until the cache runs out.
            if (node->mat_pos < node->mat_buffer.size())
                return &node->mat_buffer[node->mat_pos++];
            return nullptr;
        }

        case Operation::FOL_OPERATION_RENAME: {
            Tuple* t = Next(node->upstream);
            if (!t)
                return nullptr;

            std::vector<Attribute> attrs;
            for (const auto& a : t->attrs()) {
                std::string name = a.name;
                if (node->attrs.contains(name))
                    name = node->attrs[name];
                Attribute new_attr { name, a.value };
                attrs.push_back(new_attr);
            }
            delete t;
            return new Tuple(attrs);
        }

        case Operation::FOL_OPERATION_UNION: {
            if (node->current_node == node->nodes.end())
                return nullptr;

            Tuple* t = Next(*node->current_node);
            if (!t) {
                node->current_node++;
                return Next(node);
            }
            return t;
        }
        }

        return nullptr;
    }
} // namespace nt
