#include "VM.h"
#include "Types.h"

namespace nt
{
    VM::VM(CursorManager& cursors) : cursors_(cursors) {}

    std::vector<std::string> VM::ResolveArgs(const std::vector<PathArg>& tmpl, Tuple* from)
    {
        std::vector<std::string> resolved;
        resolved.reserve(tmpl.size());
        for (const auto& arg : tmpl)
        {
            if (arg.kind == PathArg::Kind::Const)
            {
                resolved.push_back(arg.name);
                continue;
            }
            std::string val;
            for (const auto& attr : from->attrs())
                if (attr.name == arg.name) { val = attr.value; break; }
            resolved.push_back(std::move(val));
        }
        return resolved;
    }

    void VM::ResetInner(CursorManager::cursor* c, std::vector<std::string> args)
    {
        c->args          = std::move(args);
        c->page.clear();
        c->page_position = 0;
        c->fetch_offset  = 0;
        c->exhausted     = false;
    }

    Tuple* VM::MergeInto(PlanNode* node, Tuple* left, Tuple* right)
    {
        std::vector<Attribute> merged;
        for (const auto& a : left->attrs())  merged.push_back(a);
        for (const auto& a : right->attrs()) merged.push_back(a);
        node->join_buffer.emplace(std::move(merged));
        return &*node->join_buffer;
    }

    Tuple* VM::Next(PlanNode* node)
    {
        if (node == nullptr) return nullptr;

        switch (node->op)
        {
            case Operation::FOL_OPERATION_SCAN:
                return cursors_.Next(node->scan_cursor);

            case Operation::FOL_OPERATION_PROJECT:
            {
                Tuple* next = Next(node->left);
                if (next == nullptr) return nullptr;

                std::vector<Attribute> projected;
                for (const auto& attr : next->attrs())
                {
                    if (node->project_attrs.find(attr.name) != node->project_attrs.end())
                        projected.push_back(attr);
                }

                node->project_buffer.emplace(std::move(projected));
                return &*node->project_buffer;
            }

            case Operation::FOL_OPERATION_JOIN:
            {
                while (true)
                {
                    if (node->join_left == nullptr)
                    {
                        node->join_left = Next(node->left);
                        if (node->join_left == nullptr) return nullptr;

                        auto args = ResolveArgs(node->right->scan_args, node->join_left);
                        ResetInner(node->right->scan_cursor, std::move(args));
                    }

                    Tuple* right = Next(node->right);
                    if (right != nullptr)
                        return MergeInto(node, node->join_left, right);

                    node->join_left = nullptr;
                }
            }

            case Operation::FOL_OPERATION_TAKE:
            {
                if (node->take_count >= node->take_limit) return nullptr;
                Tuple* t = Next(node->left);
                if (t) ++node->take_count;
                return t;
            }
        }

        return nullptr;
    }
}
