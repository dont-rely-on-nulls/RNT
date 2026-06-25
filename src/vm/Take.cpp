#include <vm/Take.h>

namespace nt {

    TakeNode::TakeNode(PlanNode* source, size_t limit)
        : limit(limit), source(source), count(0) {}

    Tuple* TakeNode::Next() {
        if (count >= limit)
            return nullptr;
        Tuple* t = source->Next();
        if (t)
            count++;
        return t;
    }

    void TakeNode::Rewind(Tuple* outer) {
        count = 0;
        source->Rewind(outer);
    }

}
