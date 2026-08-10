// ─────────────────────────────────────────────────────────────────────────────
// Does the engine survive NORMAL PROCESS EXIT?
//
// This cannot be a gtest case. The failure it guards against happens after
// `main` returns, inside `__cxa_finalize`, where gtest has already reported
// success — so the only honest assertion is the process's own exit status, and
// that means a separate executable whose whole body is "start an engine, then
// return 0".
//
// THE BUG. `EngineRegistry`'s function-local `State` owns every `CurlEngine`.
// `CurlEngine`'s constructor calls `curl_share_setopt(CURLOPT_SHARE)`, which
// takes the share lock, which is what first constructs the lock-callback
// mutexes. `State` is therefore constructed FIRST and destroyed LAST. With the
// mutexes in plain function-local storage they are destroyed before it, so
// `State`'s destructor — tearing the engine down, which calls
// `curl_easy_cleanup` on the parked cookie handle, which takes the cookie lock
// — calls `lock()` on a destroyed `pthread_mutex_t`. That throws
// `std::system_error` out of `~CookieBridge`, a noexcept destructor, and the
// process aborts with SIGABRT. Every app that ever made one request crashed on
// quit.
//
// The mutexes are immortal now. If somebody makes them mortal again, this
// binary exits 134 instead of 0 and CTest says so.
// ─────────────────────────────────────────────────────────────────────────────

#include <cstdio>

#include "EngineRegistry.h"

int main() {
  const nitrohttp::RoleHandle handle = nitrohttp::EngineRegistry::resolve("c:1");
  std::printf("engine resolved, role=%d\n", static_cast<int>(handle.role()));
  std::fflush(stdout);
  // Deliberately no shutdown call: the point is the path an application that
  // simply quits takes, where the registry's static destructor does the work.
  return 0;
}
