/*
 * Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
 * for details. All rights reserved. Use of this source code is governed by a
 * BSD-style license that can be found in the LICENSE file.
 */

/* Bundled by nitrogen — full self-contained implementation, no external path. */
#include "dart_api_dl.h"               /* NOLINT */
#include "dart_version.h"              /* NOLINT */
#include "internal/dart_api_dl_impl.h" /* NOLINT */

#include <stdio.h>
#include <string.h>

/* Weak: this file is copied into every nitro plugin, and two SPM plugins in one
 * app link their .o files together (GitHub #61). Identical copies coalesce. */
#if defined(_MSC_VER)
#define NITRO_DL_WEAK
#else
#define NITRO_DL_WEAK __attribute__((weak))
#endif

#define DART_API_DL_DEFINITIONS(name, R, A) NITRO_DL_WEAK name##_Type name##_DL = NULL;

DART_API_ALL_DL_SYMBOLS(DART_API_DL_DEFINITIONS)
DART_API_DEPRECATED_DL_SYMBOLS(DART_API_DL_DEFINITIONS)

#undef DART_API_DL_DEFINITIONS

typedef void* DartApiEntry_function;

NITRO_DL_WEAK DartApiEntry_function FindFunctionPointer(const DartApiEntry* entries,
                                          const char* name) {
  while (entries->name != NULL) {
    if (strcmp(entries->name, name) == 0) return entries->function;
    entries++;
  }
  return NULL;
}

DART_EXPORT NITRO_DL_WEAK void Dart_UpdateExternalSize_Deprecated(
    Dart_WeakPersistentHandle object, intptr_t external_size) {
  printf("Dart_UpdateExternalSize is a nop, it has been deprecated\n");
}

DART_EXPORT NITRO_DL_WEAK void Dart_UpdateFinalizableExternalSize_Deprecated(
    Dart_FinalizableHandle object,
    Dart_Handle strong_ref_to_object,
    intptr_t external_allocation_size) {
  printf("Dart_UpdateFinalizableExternalSize is a nop, "
         "it has been deprecated\n");
}

NITRO_DL_WEAK intptr_t Dart_InitializeApiDL(void* data) {
  DartApi* dart_api_data = (DartApi*)data;

  if (dart_api_data->major != DART_API_DL_MAJOR_VERSION) {
    return -1;
  }

  const DartApiEntry* dart_api_function_pointers = dart_api_data->functions;

#define DART_API_DL_INIT(name, R, A)                                           \
  name##_DL =                                                                  \
      (name##_Type)(FindFunctionPointer(dart_api_function_pointers, #name));
  DART_API_ALL_DL_SYMBOLS(DART_API_DL_INIT)
#undef DART_API_DL_INIT

#define DART_API_DEPRECATED_DL_INIT(name, R, A)                                \
  name##_DL = name##_Deprecated;
  DART_API_DEPRECATED_DL_SYMBOLS(DART_API_DEPRECATED_DL_INIT)
#undef DART_API_DEPRECATED_DL_INIT

  return 0;
}
