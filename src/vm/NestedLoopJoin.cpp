#include <vm/NestedLoopJoin.h>

namespace nt {

    NestedLoopJoinNode::NestedLoopJoinNode(PlanNode* left, PlanNode* right, std::unordered_set<std::string> attrs)
        : left(left), right(right), attrs(attrs) {
    }

    Tuple* NestedLoopJoinNode::Next() {
        for (;;) {
        again:
            if (!joining_on) {
                if (!(joining_on = left->Next()))
                    return nullptr;
                right->Rewind(joining_on);
            }

            Tuple* tuple = right->Next();
            if (tuple != nullptr) {
                for (auto &attr : attrs)
                    if ((*joining_on)[attr] != (*tuple)[attr])
                        goto again;

                return joining_on->MergeInto(tuple);
            }

            joining_on = nullptr;
        }
    }

    void NestedLoopJoinNode::Rewind(Tuple* outer) {
        joining_on = nullptr;
        left->Rewind(outer);
        right->Rewind(outer);
    }

}
