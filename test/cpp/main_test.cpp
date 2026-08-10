// GoogleTest entry point for the nitro_http engine suite.
//
// The engine talks to Dart through exactly two seams — `installStreamSink` and
// `setPostHook` — and both are replaced here, which is why these tests need no
// Dart VM. Installing a sink globally once (rather than per test) matches
// production: the sink is process-global because the underlying stream port
// registries are.

#include <gtest/gtest.h>

#include "support/TestSink.h"

int main(int argc, char** argv) {
  ::testing::InitGoogleTest(&argc, argv);
  nitrohttp::test::installTestSeams();
  return RUN_ALL_TESTS();
}
