#pragma once

#include "Api.h"

/**
 * @file Runtime.h
 * @brief Declares the top-level Relational NT runtime facade.
 */

namespace nt {
    /** @brief Top-level runtime object used by applications and the console entry point. */
    class NT {
      public:
        /**
         * @brief Reports whether the runtime is active.
         * @return True when the runtime is running.
         */
        bool IsRunning() const;

        /** @brief Simulates an external entry call into the runtime. */
        void SimulateEntryCall();
    };
} // namespace nt
