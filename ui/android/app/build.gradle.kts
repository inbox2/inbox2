import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    // Processes app/google-services.json (Firebase app config for FCM push).
    alias(libs.plugins.google.services)
}

// Upload key for release builds (ui/android/key.properties, gitignored; CI writes it
// from secrets). Locally: storeFile=/Users/<you>/Development/.keys/inbox2-upload.jks.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.inbox2.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.inbox2.app"
        minSdk = 26
        targetSdk = 37
        // CI sets these per build (Firebase App Distribution wants a rising code).
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "0.1"
        vectorDrawables { useSupportLibrary = true }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keyProps.isNotEmpty()) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            // No debug-key fallback: a debug-signed APK can't update the installed app.
            signingConfig = signingConfigs.findByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":inboxcore"))

    implementation(libs.core.ktx)
    implementation(libs.lifecycle.runtime.ktx)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.activity.compose)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.navigation.compose)

    implementation(libs.coroutines.android)
    implementation(libs.serialization.json)

    // inbox2 mx (domain/MX REST pool) client — Ktor over OkHttp.
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.json)

    // OAuth onboarding via Custom Tabs; avatars via Coil; prefs via DataStore;
    // background sync via WorkManager.
    implementation(libs.browser)
    implementation(libs.coil.compose)
    implementation(libs.datastore.preferences)
    implementation(libs.work.runtime.ktx)

    // On-device LLM (LiteRT / Gemma) for the Bridge NLU free lane.
    implementation(libs.mediapipe.genai)

    // Encrypted-at-rest secrets (Keystore-backed) for the mx token / API keys —
    // the Android counterpart to the iOS Keychain.
    implementation(libs.security.crypto)

    // On-device language identification (bundled model) — per-sentence TTS voice
    // routing for the Bridge, the Android counterpart to iOS NaturalLanguage.
    implementation(libs.mlkit.language.id)

    // FCM push: silent "go sync" nudges + visible MX-mail alerts from the API
    // (docs/Cloud-Push.md "Mobile push").
    implementation(libs.firebase.messaging)

    // Android Auto (projected) — Bridge briefs on the car head unit (docs/Android-App.md).
    implementation(libs.car.app)

    debugImplementation(libs.compose.ui.tooling)

    // Instrumented rendering harness (EmailBodyRenderingTest): runs the shipped
    // email-body bundle in a real WebView on the emulator/device. Direct coordinates
    // — these aren't in the version catalog.
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
}

// Bundle the shared rendering corpus into the instrumented-test APK so
// EmailBodyRenderingTest can run every fixture through the shipped bundle in a real
// WebView. fixtures.gen.json is produced by bin/gen-email-fixtures; the email-body.js
// bundle is already a main app asset (read via the target context). AGP 9 removed the
// sourceSets DSL for this — androidTest assets now come off the Sources API.
androidComponents {
    onVariants { variant ->
        variant.androidTest?.sources?.assets?.addStaticSourceDirectory(
            rootProject.file("../../fixtures/email").path
        )
    }
}
