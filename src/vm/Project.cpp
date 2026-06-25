#include "Types.h"
#include <vm/Project.h>

namespace nt {

    ProjectNode::ProjectNode(PlanNode* source, std::unordered_set<std::string> attrs)
        : source(source), attrs(attrs)
    {}

    Tuple* ProjectNode::Next() {
        Tuple* next = source->Next();
        if (next == nullptr)
            return nullptr;

        std::vector<Attribute> projected;
        for (const auto& attr : next->attrs())
            if (attrs.find(attr.name) != attrs.end())
                projected.push_back(attr);

        return new Tuple(projected);
    }

    void ProjectNode::Rewind(Tuple* outer) {
        source->Rewind(outer);
    }
}
