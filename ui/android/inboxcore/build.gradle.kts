plugins {
    alias(libs.plugins.android.library)
}

// The shared Rust core (`inbox2-core`) reaches Android through UniFFI Kotlin
// bindings — the exact same `InboxEngine` surface the iOS app drives via Swift.
// Rather than copy the build outputs in, this module points its source/jniLibs dirs
// straight at what `ui/desktop/core/build-android-jni.sh` produces:
//   - per-ABI `libinbox2_core.so`         → ../../desktop/target/android-jniLibs
//   - generated `uniffi/.../inbox2_core.kt`→ ../../desktop/target/uniffi-kotlin
// Re-run that script after any Rust change, then rebuild.
android {
    namespace = "com.inbox2.core"
    compileSdk = 37

    defaultConfig {
        minSdk = 26
        ndk {
            // Match the ABIs the Rust build produces.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// AGP 9 removed the `sourceSets[..].srcDir(..)` DSL in favour of the per-variant
// Sources API. Both directories are produced by ui/desktop/core/build-android-jni.sh
// — fail loudly rather than silently building an APK with no native library.
androidComponents {
    onVariants { variant ->
        fun coreOutput(name: String) =
            rootProject.file("../desktop/target/$name").also {
                require(it.isDirectory) {
                    "missing $it — run ui/desktop/core/build-android-jni.sh first"
                }
            }.path

        variant.sources.jniLibs?.addStaticSourceDirectory(coreOutput("android-jniLibs"))
        variant.sources.kotlin?.addStaticSourceDirectory(coreOutput("uniffi-kotlin"))
    }
}

dependencies {
    // UniFFI's generated Kotlin uses JNA to call into the native library.
    implementation(libs.jna) {
        artifact { type = "aar" }
    }
    implementation(libs.coroutines.android)
}
