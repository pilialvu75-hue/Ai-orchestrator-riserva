#pragma once

namespace startup_trace {

// Resets the per-launch startup trace stored in the user's temporary folder.
// The implementation intentionally uses Win32 APIs only so it can record the
// last successful startup stage even when the C runtime or Flutter aborts.
void Reset();

// Appends and flushes one startup stage marker.
void Mark(const char* stage);

}  // namespace startup_trace
