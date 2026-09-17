plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.stylepos.stylepos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.stylepos.stylepos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // mobile_scanner (CameraX) requires minSdk 23+; 24 covers all supported devices.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Permanent upload signing key, provided by CI through environment
    // variables (GitHub Actions secrets). Absent locally -> debug signing.
    val uploadKeystorePath = System.getenv("STYLEPOS_UPLOAD_KEYSTORE")

    signingConfigs {
        if (uploadKeystorePath != null) {
            create("upload") {
                storeFile = file(uploadKeystorePath)
                storePassword = System.getenv("STYLEPOS_UPLOAD_KEY_PASSWORD")
                keyAlias = System.getenv("STYLEPOS_UPLOAD_KEY_ALIAS") ?: "stylepos"
                keyPassword = System.getenv("STYLEPOS_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (uploadKeystorePath != null) {
                signingConfigs.getByName("upload")
            } else {
                // Local development fallback only.
                signingConfigs.getByName("debug")
            }
            // Shrink Java/Kotlin bytecode and unused Android resources with R8.
            // The APK is dominated by native libraries; this trims the JVM side.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
