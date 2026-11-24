package dev.shreeman.nitro_http_dartnative_example

import com.dartnative.runtime.DartNativeApplication

class Application : DartNativeApplication() {
    // The base class owns the engine bootstrap (JNI bridge load, engine
    // pre-warm). Override onEngineCreated() for custom native setup.
}
