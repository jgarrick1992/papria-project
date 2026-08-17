import org.gradle.api.GradleException
import java.security.MessageDigest
import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val roomProcessorEnabled = providers.gradleProperty("roomProcessor").orNull != "false"
if (roomProcessorEnabled) apply(plugin = "kotlin-kapt")
val nativeFormatCoreLibrary = "libuniffi_papria_format_core.so"
val nativeFormatCoreAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val nativeFormatCoreArtifacts = rootProject.file("../shared/format-core/artifacts/android")
val nativeFormatCoreBinding = rootProject.file(
    "../shared/format-core/bindings/generated/uniffi/papria_format_core/papria_format_core.kt",
)
val readiumVersion = "3.1.2"

android {
    namespace = "com.papria.reader"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.papria.reader"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // The release graph uses slf4j-android for Junrar. JVM tests do not have
    // android.util.Log, so remove that Android-only binding from the test
    // runtime and let slf4j-api use its no-op fallback instead.
    testOptions {
        unitTests.isReturnDefaultValues = false
    }

    buildTypes.configureEach { buildConfigField("boolean", "NATIVE_FORMAT_CORE", "true") }

    lint {
        // MainActivity extends ComponentActivity directly and never uses
        // FragmentActivity or FragmentManager. The detector is a false
        // positive caused by a legacy transitive Fragment artifact.
        disable += "InvalidFragmentVersionForActivityResult"
        // AndroidX Lifecycle's detector currently crashes against the
        // Kotlin Analysis API bundled with Kotlin 2.1.21. Keep lint useful
        // for the rest of the project while this upstream binary mismatch
        // is resolved.
        disable += "NullSafeMutableLiveData"
    }

    sourceSets.getByName("main").java.srcDir(
        nativeFormatCoreBinding.parentFile.parentFile,
    )
    sourceSets.getByName("main").jniLibs.srcDir(nativeFormatCoreArtifacts)
}

/**
 * Every Android variant is a shared-format-core delivery. Building the core
 * before preBuild keeps generated Kotlin, ABI libraries and Rust sources in
 * lockstep; a missing Rust/NDK/UniFFI prerequisite is a build failure rather
 * than a platform-parser fallback.
 */
val buildFormatCoreAndroid by tasks.registering(Exec::class) {
    group = "build setup"
    description = "Generates UniFFI bindings and builds the four Android format-core ABIs."
    val workspaceRoot = rootProject.file("..")
    workingDir = workspaceRoot
    commandLine("bash", "scripts/build-format-core.sh", "android")
    environment("PAPRIA_NATIVE_OUT", nativeFormatCoreArtifacts.parentFile.absolutePath)
    inputs.files(
        rootProject.file("../scripts/build-format-core.sh"),
        rootProject.file("../scripts/generate-format-bindings.sh"),
        fileTree(rootProject.file("../shared/format-core")) {
            include("Cargo.toml", "Cargo.lock", "build.rs", "src/**", "native/**", "vendor/libmobi/**")
        },
    )
    outputs.dir(nativeFormatCoreArtifacts)
}
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn(buildFormatCoreAndroid)
}

/**
 * Verifies the physical Android release artifact, not just Gradle source-set
 * wiring. This catches a missing ABI directory or a packaging regression while
 * preserving the no-binary-in-Git policy.
 */
val verifyNativeCoreReleasePackage by tasks.registering {
    group = "verification"
    description = "Verifies that the Release APK contains every native format-core ABI."
    dependsOn("assembleRelease")

    doLast {
        check(nativeFormatCoreBinding.isFile) {
            "Missing generated UniFFI Kotlin binding: ${nativeFormatCoreBinding.path}. " +
                "Run scripts/generate-format-bindings.sh."
        }
        val missingLibraries = nativeFormatCoreAbis.filter { abi ->
            !nativeFormatCoreArtifacts.resolve("$abi/$nativeFormatCoreLibrary").isFile
        }
        check(missingLibraries.isEmpty()) {
            "Missing native format-core libraries for: ${missingLibraries.joinToString()}. " +
                "Run scripts/build-format-core.sh android."
        }

        val releaseApks = fileTree(layout.buildDirectory.dir("outputs/apk/release")) {
            include("*.apk")
        }.files
        check(releaseApks.size == 1) {
            "Expected exactly one Release APK, found ${releaseApks.size} under build/outputs/apk/release."
        }
        val expectedEntries = nativeFormatCoreAbis.map { abi ->
            "lib/$abi/$nativeFormatCoreLibrary"
        }
        ZipFile(releaseApks.single()).use { apk ->
            val missingEntries = expectedEntries.filter { entry -> apk.getEntry(entry) == null }
            check(missingEntries.isEmpty()) {
                "Release APK is missing native format-core libraries: ${missingEntries.joinToString()}."
            }
        }
    }
}

/** The debug APK is also a real product path and must package every ABI. */
val verifyNativeCoreDebugPackage by tasks.registering {
    group = "verification"
    description = "Verifies that the Debug APK contains every native format-core ABI."
    dependsOn("assembleDebug")

    doLast {
        check(nativeFormatCoreBinding.isFile) {
            "Missing generated UniFFI Kotlin binding: ${nativeFormatCoreBinding.path}."
        }
        val missingLibraries = nativeFormatCoreAbis.filter { abi ->
            !nativeFormatCoreArtifacts.resolve("$abi/$nativeFormatCoreLibrary").isFile
        }
        check(missingLibraries.isEmpty()) {
            "Missing native format-core libraries for: ${missingLibraries.joinToString()}."
        }
        val debugApks = fileTree(layout.buildDirectory.dir("outputs/apk/debug")) {
            include("*.apk")
        }.files
        check(debugApks.size == 1) {
            "Expected exactly one Debug APK, found ${debugApks.size} under build/outputs/apk/debug."
        }
        val expectedEntries = nativeFormatCoreAbis.map { abi ->
            "lib/$abi/$nativeFormatCoreLibrary"
        }
        ZipFile(debugApks.single()).use { apk ->
            val missingEntries = expectedEntries.filter { entry -> apk.getEntry(entry) == null }
            check(missingEntries.isEmpty()) {
                "Debug APK is missing native format-core libraries: ${missingEntries.joinToString()}."
            }
        }
    }
}

/**
 * LibVLC is deliberately a real runtime dependency, not a reflective class
 * name. Verify both the locked Maven artifact and the physical Release APK so
 * a dependency-resolution or packaging regression cannot silently remove the
 * fallback decoder.
 */
val verifyLibVlcReleasePackage by tasks.registering {
    group = "verification"
    description = "Verifies LibVLC's locked artifact and native libraries in the Release APK."
    dependsOn("assembleRelease")

    doLast {
        val libVlcArtifact = configurations.getByName("releaseRuntimeClasspath").files.singleOrNull { file ->
            file.name == "libvlc-all-3.6.5.aar"
        } ?: throw GradleException("Release runtime classpath is missing LibVLC 3.6.5.")
        val messageDigest = MessageDigest.getInstance("SHA-256")
        val digest = libVlcArtifact.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                messageDigest.update(buffer, 0, count)
            }
            messageDigest.digest().joinToString("") { byte -> "%02x".format(byte) }
        }
        check(digest == "6a15a1f7acd0738a31acce0c7e5eb6f5f340b62e6b64d8f83df547da56a44b47") {
            "LibVLC artifact checksum did not match the reviewed 3.6.5 release."
        }

        val releaseApks = fileTree(layout.buildDirectory.dir("outputs/apk/release")) {
            include("*.apk")
        }.files
        check(releaseApks.size == 1) {
            "Expected exactly one Release APK, found ${releaseApks.size} under build/outputs/apk/release."
        }
        ZipFile(releaseApks.single()).use { apk ->
            val missing = nativeFormatCoreAbis.flatMap { abi ->
                listOf("lib/$abi/libvlc.so", "lib/$abi/libvlcjni.so")
            }.filter { entry -> apk.getEntry(entry) == null }
            check(missing.isEmpty()) {
                "Release APK is missing packaged LibVLC binaries: ${missing.joinToString()}."
            }
        }
    }
}

configurations.configureEach {
    if (name.contains("test", ignoreCase = true) && name.endsWith("RuntimeClasspath")) {
        exclude(group = "org.slf4j", module = "slf4j-android")
    }
}

dependencies {
    // Readium 3.1.2 uses java.time and other APIs supplied through the
    // Android core-library desugaring contract on API 23 devices.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation(platform("androidx.compose:compose-bom:2026.08.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    // Readium is the production renderer for EPUB/KEPUB and the internal
    // EPUB files generated by the shared MOBI/FB2 converter. Its official
    // PDFium adapter is the Android PDF engine.
    implementation("org.readium.kotlin-toolkit:readium-shared:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-streamer:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-navigator:$readiumVersion")
    implementation("org.readium.kotlin-toolkit:readium-adapter-pdfium:$readiumVersion")
    // Media3 owns the ExoPlayer queue, MediaSession notification, audio focus,
    // media buttons and lock-screen/Android Auto transport controls.
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-session:1.5.1")
    // Secondary decoder for Media3 renderer/container failures. The checksum
    // and APK contents are verified by verifyLibVlcReleasePackage.
    implementation("org.videolan.android:libvlc-all:3.6.5")
    implementation("androidx.room:room-runtime:2.7.2")
    implementation("androidx.room:room-ktx:2.7.2")
    if (roomProcessorEnabled) add("kapt", "androidx.room:room-compiler:2.7.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Apache Commons Compress supplies bounded 7z/CB7 extraction. Junrar
    // decodes RAR4 compressed CBR members only after the local parser has
    // validated names, archive limits and non-encryption flags.
    implementation("org.apache.commons:commons-compress:1.21")
    implementation("org.tukaani:xz:1.9")
    implementation("com.github.junrar:junrar:7.5.5")
    // Junrar uses SLF4J at runtime. Keep an Android binding in the release
    // graph so R8 does not leave StaticLoggerBinder unresolved.
    implementation("org.slf4j:slf4j-android:1.7.36")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("com.google.zxing:core:3.5.3")
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
