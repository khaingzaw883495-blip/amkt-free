import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // v1.0.5: Firebase Analytics (google-services.json in android/app/).
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing with the shared Amkt keystore (passwords only in
// android/key.properties, which is git-ignored and never shared).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.amkt.vpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // v1.0.2: flutter_local_notifications requires core library
        // desugaring for the app (it uses java.time APIs).
        isCoreLibraryDesugaringEnabled = true
    }

    // v1.0.5: KGP 2.4.0 removed the old kotlinOptions DSL — jvmTarget must
    // now be set via compilerOptions inside the kotlin block (see build
    // failure 2026-11-12).
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.amkt.vpn"
        // sing-box core needs API 24+; arm64 only (practically every phone).
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    // openvpn_flutter: the OpenVPN engine runs from a native library, so
    // the library must be extracted when the app is installed.
    // v1.0.7 — arm64-only APK: ndk.abiFilters (defaultConfig, above)
    // does NOT filter prebuilt .so files from plugin AARs (sing-box
    // ships libbox.so for arm64-v8a + armeabi-v7a + x86_64, and the
    // --target-platform flag only controls Flutter's own libs), so the
    // other ABIs are excluded here at packaging time. This drops the
    // APK from ~72 MB to ~31 MB. arm64 covers practically every phone.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += "lib/armeabi-v7a/**"
            excludes += "lib/x86_64/**"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

dependencies {
    // v1.0.2: core library desugaring (required by
    // flutter_local_notifications).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
