#include <vm/Scan.h>

namespace nt {

    ScanNode::ScanNode(CursorManager::cursor* cursor, std::vector<PathArg> args,
                       CursorManager& cursorManager)
        : cursor(cursor), args(args), cursorManager(cursorManager) {
    }

    static std::vector<std::string> ResolveArgs(const std::vector<PathArg>& tmpl, Tuple* from) {
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

    Tuple* ScanNode::Next() {
        return cursorManager.Next(cursor);
    }

    void ScanNode::ResetInner(std::vector<std::string> args) {
        // TODO: move this to CursorManager::cursor
        cursor->args = std::move(args);
        cursor->page.clear();
        cursor->page_position = 0;
        cursor->fetch_offset = 0;
        cursor->exhausted = false;
    }

    void ScanNode::Rewind(Tuple* outer) {
        ResetInner(ResolveArgs(args, outer));
    }

} // namespace nt
