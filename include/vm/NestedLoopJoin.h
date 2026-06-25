#include <VM.h>

namespace nt {

    class NestedLoopJoinNode : PlanNode {
      public:
        NestedLoopJoinNode(PlanNode* left, PlanNode* right, std::unordered_set<std::string> attrs);

        Tuple* Next();
        void Rewind(Tuple* outer);

      private:
        PlanNode* left;
        PlanNode* right;
        Tuple* joining_on;
        std::unordered_set<std::string> attrs;
    };

}
