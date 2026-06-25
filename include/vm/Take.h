#include <VM.h>
#include <cstddef>

namespace nt {
    class TakeNode : PlanNode {
    public:
        TakeNode(PlanNode* source, size_t limit);

        Tuple* Next();
        void Rewind(Tuple* outer);
    private:
        PlanNode* source;
        size_t limit, count;
    };
}
