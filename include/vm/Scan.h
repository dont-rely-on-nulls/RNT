#include "CursorManager.h"
#include <VM.h>

namespace nt {
    class ScanNode : PlanNode {
      public:
        ScanNode(CursorManager::cursor* cursor, std::vector<PathArg> args,
                 CursorManager& cursorManager);

        Tuple* Next();
        void Rewind(Tuple* outer);

      private:
        void ResetInner(std::vector<std::string> args);

        CursorManager::cursor* cursor = nullptr;
        std::vector<PathArg> args;
        CursorManager& cursorManager;
    };
} // namespace nt
