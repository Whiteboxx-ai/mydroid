plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.mydroid.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.whiteboxxai.mydroid"
        minSdk = 29
        // Keep at 36: Android 17 holds OTP SMS for 3 hours for apps targeting API 37+, which would defeat SmsOtpReceiver.
        targetSdk = 36
        versionCode = (System.getenv("MYDROID_VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("MYDROID_VERSION_NAME") ?: "0.1.0"
    }

    // Release signing comes from the environment (scripts/release/build.sh), so no key is ever in the repo.
    val keystore = System.getenv("MYDROID_KEYSTORE")
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("MYDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MYDROID_KEY_ALIAS") ?: "mydroid"
                keyPassword = System.getenv("MYDROID_KEY_PASSWORD") ?: System.getenv("MYDROID_KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { buildConfig = true }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                // Roborazzi: write screenshots (record mode) to an explicit directory.
                it.systemProperty("roborazzi.test.record", "true")
                it.systemProperty("render.dir", System.getProperty("render.dir")
                    ?: layout.buildDirectory.dir("renders").get().asFile.path)
                it.maxHeapSize = "2g"
            }
        }
    }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    // The app has no Fragments (ComponentActivity + Compose), so this check, which looks for an old Fragment library, can't apply.
    lint { disable += "InvalidFragmentVersionForActivityResult" }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":protocol"))
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core:1.7.8")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Screenshot tests (JVM, no device): Robolectric native graphics + Roborazzi.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.18.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.79.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.79.0")
    testImplementation("androidx.compose.ui:ui-test-junit4")
}
