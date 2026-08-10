/// The one-time handshake between a Dart isolate incarnation and the native
/// engine.
///
/// **Why this exists.** A hot restart tears down the Dart isolate and starts a
/// fresh one, but the plugin's native side is process state: engine loop
/// threads keep running, transfers keep transferring, cookie jars stay dirty,
/// and the cancellation registry keeps every token the old isolate created.
/// Nothing in Flutter tells a plugin this happened.
///
/// The library used to answer that by documenting `NitroHttp.reset()` and
/// asking every app to call it from `main()`. That is the wrong shape for an
/// API: it is invisible until it bites, the symptoms (ghost sockets, a request
/// that cancels itself) look nothing like a missing call, and it is only ever
/// needed during development — so the people most likely to hit it are exactly
/// the ones who have not read that far into the docs.
///
/// So the reset runs itself. [ensureNativeAttached] is called before the first
/// native instance of any role is created, and the guard below is an ordinary
/// static, which a hot restart resets along with the rest of the isolate.
/// First touch in a fresh incarnation therefore always reconciles native state,
/// and every later touch is a single already-true bool test.
library;

import 'dart:isolate';

import '../nitro_http.native.dart';
import 'instance_keys.dart';

bool _attached = false;

/// Whether the handshake has already run in this isolate. Test seam.
bool get nativeAttachedForTesting => _attached;

/// Forgets the handshake, so the next call runs it again. Test seam: a test
/// cannot restart the isolate, but it can put this back the way a restart does.
void resetNativeAttachForTesting() => _attached = false;

/// Reconciles native state with this isolate incarnation. Idempotent, and cheap
/// enough to call on every path that reaches native.
///
/// On a cold start there is nothing to clean up and this costs one sub-
/// microsecond FFI call. After a hot restart it aborts every straggling
/// transfer, joins the engine threads, flushes the cookie jars and clears the
/// cancellation registry.
void ensureNativeAttached() {
  if (_attached) return;
  // Set BEFORE the work: `resetNative` builds an engine-role instance, and a
  // re-entrant call must see the handshake as already under way rather than
  // recursing into it.
  _attached = true;

  // Only the isolate that owns the plugin may reconcile it. A background
  // isolate reaching native would otherwise abort the transfers the root
  // isolate has in flight — its own statics are fresh, so it cannot tell a hot
  // restart from simply being new. Skipping is the safe direction: the worst
  // case is the pre-existing behaviour, where nothing is reset until something
  // asks.
  //
  // (The bridge's stream registry is module-global with a single subscriber, so
  // driving this plugin from several isolates is unsupported anyway.)
  if (Isolate.current.debugName != 'main') return;

  NitroHttpNative.forKey(kEngineKey).resetNative();
}

/// Builds the native instance for [key], reconciling this incarnation first.
///
/// Every native role goes through here rather than calling `forKey` directly,
/// so the handshake cannot be missed by a caller that reaches native by an
/// unusual route — a bare `NitroHttpClient`, a WebSocket, or a capability
/// getter — and so the ordering is fixed: reconcile, then create.
NitroHttpNative attachedNative(String key) {
  ensureNativeAttached();
  return NitroHttpNative.forKey(key);
}
