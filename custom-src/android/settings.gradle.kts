pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // v1.0.5: Kotlin 2.4.0 is REQUIRED, not optional — firebase_analytics
    // 13.0.1 pulls play-services-measurement 24.0.0, whose Kotlin metadata
    // is binary version 2.4.0; KGP 2.2.20 fails with "Module was compiled
    // with an incompatible version of Kotlin ... expected version is 2.2.0".
    // (Gradle 8.14 + AGP 8.11.1 accept KGP 2.4.0.)
    // v1.0.5: Firebase Analytics — google-services plugin reads
    // google-services.json (already staged in android/app/).
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
