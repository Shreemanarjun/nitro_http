allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// nitro_http links a per-ABI prebuilt libcurl slice, so configuring an ABI you
// have no slice for is a hard CMake error, not a skipped variant. AGP builds
// EVERY abi for a *library* module regardless of what the application module
// filters — and the plugin deliberately sets no abiFilters of its own, because
// restricting ABIs is the consumer's call. This is the consumer, so make the
// call here: honour the `-Ptarget-platform` that `flutter build`/`flutter drive`
// already pass for the selected device, in the plugin modules too.
//
// Without the flag nothing is restricted, so a plain `./gradlew assembleRelease`
// still builds the full set (and still needs the full set of slices).
val abiForFlutterTargetPlatform = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x86" to "x86",
    "android-x64" to "x86_64",
)
val requestedAbis: List<String> =
    (findProperty("target-platform") as String?)
        ?.split(',')
        ?.mapNotNull { abiForFlutterTargetPlatform[it.trim()] }
        .orEmpty()

if (requestedAbis.isNotEmpty()) {
    subprojects {
        pluginManager.withPlugin("com.android.library") {
            extensions.configure(com.android.build.api.dsl.LibraryExtension::class.java) {
                defaultConfig.externalNativeBuild.cmake.abiFilters.apply {
                    clear()
                    addAll(requestedAbis)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
