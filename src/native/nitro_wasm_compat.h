// Emscripten compatibility shim for nitro bridges.
//
// Generated bridges post async/stream results with Dart_PostCObject_DL. On
// the web there is no Dart VM: the Dart side registers a function-table
// callback per module (Module.addFunction) through `<lib>_nitro_set_post_fn`,
// and this header maps every existing Dart_PostCObject_DL call site onto it —
// so the generated post code compiles unchanged.
//
// Post envelope: (port, tag, a, b, d)
//   tag 0 = kNull
//   tag 1 = kInt64 / kInt32 / kBool         (value in a)
//   tag 2 = kDouble                          (value in d)
//   tag 3 = kString  (a = const char*, BORROWED — Dart decodes synchronously)
//   tag 4 = int64 array (a = int64_t* buf, b = count, BORROWED)
//   tag 5 = string array (a = const char** buf, b = count, BORROWED —
//           string-batch streams)
//   tag 6 = byte buffer (a = const uint8_t*, b = byte count, BORROWED —
//           record/variant batch streams posted as kTypedData)
// kInt64 posts that carry heap addresses keep their transfer-to-Dart
// semantics: Dart frees them via `<lib>_nitro_free`, exactly as on native.
#ifndef NITRO_WASM_COMPAT_H_
#define NITRO_WASM_COMPAT_H_

#ifndef __EMSCRIPTEN__
#error "nitro_wasm_compat.h is only for Emscripten builds; include dart_api_dl.h instead"
#endif

#include <stdint.h>
#if defined(__EMSCRIPTEN_PTHREADS__)
#include <emscripten/threading.h>  // C++ templates — must sit outside extern "C"
#include <string.h>
#endif
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t Dart_Port_DL;

typedef enum {
  Dart_CObject_kNull = 0,
  Dart_CObject_kBool,
  Dart_CObject_kInt32,
  Dart_CObject_kInt64,
  Dart_CObject_kDouble,
  Dart_CObject_kString,
  Dart_CObject_kArray,
  Dart_CObject_kTypedData,
} Dart_CObject_Type;

typedef enum {
  Dart_TypedData_kByteData = 0,
  Dart_TypedData_kInt8,
  Dart_TypedData_kUint8,
  Dart_TypedData_kInt16,
  Dart_TypedData_kUint16,
  Dart_TypedData_kInt32,
  Dart_TypedData_kUint32,
  Dart_TypedData_kInt64,
  Dart_TypedData_kUint64,
  Dart_TypedData_kFloat32,
  Dart_TypedData_kFloat64,
} Dart_TypedData_Type;

typedef struct _Dart_CObject {
  Dart_CObject_Type type;
  union {
    bool as_bool;
    int32_t as_int32;
    int64_t as_int64;
    double as_double;
    const char* as_string;
    struct {
      intptr_t length;
      struct _Dart_CObject** values;
    } as_array;
    struct {
      Dart_TypedData_Type type;
      intptr_t length;  // in elements, not bytes
      const uint8_t* values;
    } as_typed_data;
  } value;
} Dart_CObject;

typedef void (*NitroPostFn)(int64_t port, int32_t tag, int64_t a, int64_t b,
                            double d);

// One post slot per wasm binary (the port id disambiguates modules). Weak so
// every bridge TU can include this header; wasm-ld merges the definitions.
__attribute__((weak)) NitroPostFn g_nitro_post_fn = 0;

#if defined(__EMSCRIPTEN_PTHREADS__)
// Threaded build (-pthread): the post callback is a JS function that exists
// only in the MAIN thread's realm — a worker must not call it. Payloads are
// borrowed-and-consumed-synchronously on the main path, so the worker path
// COPIES them and hands ownership to a packet delivered on the main runtime
// thread. Unthreaded builds compile exactly the code below this block.
typedef struct {
  int64_t port; int32_t tag; int64_t a; int64_t b; double d; void* owned;
} _NitroPostPkt;
static void _nitro_deliver_on_main(void* arg) {
  _NitroPostPkt* pkt = (_NitroPostPkt*)arg;
  if (g_nitro_post_fn) g_nitro_post_fn(pkt->port, pkt->tag, pkt->a, pkt->b, pkt->d);
  free(pkt->owned);
  free(pkt);
}
// owned: heap block freed after delivery (the payload copy, or NULL).
static inline bool _nitro_post_from_worker(int64_t port, int32_t tag, int64_t a,
                                           int64_t b, double d, void* owned) {
  _NitroPostPkt* pkt = (_NitroPostPkt*)malloc(sizeof(_NitroPostPkt));
  if (!pkt) { free(owned); return false; }
  pkt->port = port; pkt->tag = tag; pkt->a = a; pkt->b = b; pkt->d = d; pkt->owned = owned;
  emscripten_dispatch_to_thread_async(emscripten_main_runtime_thread_id(),
                                      EM_FUNC_SIG_VI, (void*)_nitro_deliver_on_main,
                                      NULL, pkt);
  return true;
}
#define _NITRO_OFF_MAIN() (!emscripten_is_main_runtime_thread())
#else
#define _NITRO_OFF_MAIN() 0
#define _nitro_post_from_worker(port, tag, a, b, d, owned) (false)
#endif

static inline bool Dart_PostCObject_DL(Dart_Port_DL port, Dart_CObject* obj) {
  if (!g_nitro_post_fn) return false;
  switch (obj->type) {
    case Dart_CObject_kNull:
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 0, 0, 0, 0.0, 0);
      g_nitro_post_fn(port, 0, 0, 0, 0.0);
      return true;
    case Dart_CObject_kBool:
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 1, obj->value.as_bool ? 1 : 0, 0, 0.0, 0);
      g_nitro_post_fn(port, 1, obj->value.as_bool ? 1 : 0, 0, 0.0);
      return true;
    case Dart_CObject_kInt32:
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 1, obj->value.as_int32, 0, 0.0, 0);
      g_nitro_post_fn(port, 1, obj->value.as_int32, 0, 0.0);
      return true;
    case Dart_CObject_kInt64:
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 1, obj->value.as_int64, 0, 0.0, 0);
      g_nitro_post_fn(port, 1, obj->value.as_int64, 0, 0.0);
      return true;
    case Dart_CObject_kDouble:
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 2, 0, 0, obj->value.as_double, 0);
      g_nitro_post_fn(port, 2, 0, 0, obj->value.as_double);
      return true;
    case Dart_CObject_kString:
#if defined(__EMSCRIPTEN_PTHREADS__)
      if (_NITRO_OFF_MAIN()) {
        char* copy = strdup(obj->value.as_string);
        if (!copy) return false;
        return _nitro_post_from_worker(port, 3, (int64_t)(intptr_t)copy, 0, 0.0, copy);
      }
#endif
      g_nitro_post_fn(port, 3, (int64_t)(intptr_t)obj->value.as_string, 0, 0.0);
      return true;
    case Dart_CObject_kArray: {
      // Bridges post flat arrays of kInt64 (batch streams, coalescer) or of
      // kString (string-batch streams). Flatten into a temp buffer; the Dart
      // callback copies it synchronously.
      const intptr_t n = obj->value.as_array.length;
      if (n > 0 && obj->value.as_array.values[0]->type == Dart_CObject_kString) {
        const char** buf = (const char**)malloc((size_t)n * sizeof(const char*));
        if (!buf) return false;
        for (intptr_t i = 0; i < n; i++) {
          buf[i] = obj->value.as_array.values[i]->value.as_string;
        }
#if defined(__EMSCRIPTEN_PTHREADS__)
        if (_NITRO_OFF_MAIN()) {
          // Deep-copy into ONE block: [char* x n][string bytes...] so a single
          // free releases everything after delivery.
          size_t total = (size_t)n * sizeof(char*);
          for (intptr_t i = 0; i < n; i++) total += strlen(buf[i]) + 1;
          char** blob = (char**)malloc(total);
          if (!blob) { free(buf); return false; }
          char* w = (char*)(blob + n);
          for (intptr_t i = 0; i < n; i++) {
            size_t len = strlen(buf[i]) + 1;
            memcpy(w, buf[i], len);
            blob[i] = w;
            w += len;
          }
          free(buf);
          return _nitro_post_from_worker(port, 5, (int64_t)(intptr_t)blob, (int64_t)n, 0.0, blob);
        }
#endif
        g_nitro_post_fn(port, 5, (int64_t)(intptr_t)buf, (int64_t)n, 0.0);
        free(buf);
        return true;
      }
      int64_t* buf = (int64_t*)malloc((size_t)n * sizeof(int64_t));
      if (!buf && n > 0) return false;
      for (intptr_t i = 0; i < n; i++) {
        buf[i] = obj->value.as_array.values[i]->value.as_int64;
      }
      if (_NITRO_OFF_MAIN()) return _nitro_post_from_worker(port, 4, (int64_t)(intptr_t)buf, (int64_t)n, 0.0, buf);
      g_nitro_post_fn(port, 4, (int64_t)(intptr_t)buf, (int64_t)n, 0.0);
      free(buf);
      return true;
    }
    case Dart_CObject_kTypedData: {
      // Record/variant batch streams post a Uint8 buffer. Length is in
      // elements — for kUint8 that equals bytes (the only type bridges post).
#if defined(__EMSCRIPTEN_PTHREADS__)
      if (_NITRO_OFF_MAIN()) {
        const int64_t len = (int64_t)obj->value.as_typed_data.length;
        uint8_t* copy = (uint8_t*)malloc(len > 0 ? (size_t)len : 1);
        if (!copy) return false;
        memcpy(copy, obj->value.as_typed_data.values, (size_t)len);
        return _nitro_post_from_worker(port, 6, (int64_t)(intptr_t)copy, len, 0.0, copy);
      }
#endif
      g_nitro_post_fn(port, 6,
                      (int64_t)(intptr_t)obj->value.as_typed_data.values,
                      (int64_t)obj->value.as_typed_data.length, 0.0);
      return true;
    }
  }
  return false;
}

// The web Dart runtime never performs the VM handshake; succeed so generated
// init paths work unchanged.
static inline intptr_t Dart_InitializeApiDL(void* data) {
  (void)data;
  return 0;
}

#ifdef __cplusplus
}  // extern "C"
#endif

// Hot-restart safety: the generated bridge defines (via EM_JS — a JS glue
// function, not a wasm export) nitro_web_instance_changed(), which reports 1 the first time each module
// instance asks. Plugin web impls call it from their EM_JS bootstrap to
// rebuild globalThis helpers that would otherwise close over a dead heap.

#endif  // NITRO_WASM_COMPAT_H_
