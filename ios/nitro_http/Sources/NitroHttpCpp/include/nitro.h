#pragma once

#include <stdint.h>
#include <stdbool.h>

#if _WIN32
#define NITRO_EXPORT __declspec(dllexport)
#else
#define NITRO_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NITRO_ERROR_DEFINED
#define NITRO_ERROR_DEFINED
typedef struct {
  int8_t hasError;
  const char* name;
  const char* message;
  const char* code;
  const char* stackTrace;
} NitroError;
#endif

#ifdef __cplusplus
}
#endif
