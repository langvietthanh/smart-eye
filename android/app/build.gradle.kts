plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.smart_eye"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.smart_eye"
        minSdk = flutter.minSdkVersion                          // tflite_flutter yêu cầu tối thiểu API 21
        targetSdk = flutter.targetSdkVersion
        compileSdk = 36                      // camera/tflite/tts yêu cầu compileSdk >= 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABI filters: x86_64 cho emulator, arm64-v8a cho thiết bị thật
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
