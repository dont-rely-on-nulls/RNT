#include <VM.h>

namespace nt {

    class ProjectNode : PlanNode {
      public:
        ProjectNode(PlanNode* source, std::unordered_set<std::string> attrs);

        Tuple* Next();
        void Rewind(Tuple* outer);

      private:
        std::unordered_set<std::string> attrs;
        std::optional<Tuple> buffer;
        PlanNode* source;
    };

}
