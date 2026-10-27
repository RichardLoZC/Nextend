plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dev.padbridge"
    compileSdk = 36
    defaultConfig { applicationId = "dev.padbridge"; minSdk = 30; targetSdk = 36; versionCode = 16; versionName = "0.8.2" }
    // Preserve the installed APK identity. Never silently create a replacement key.
    signingConfigs {
        getByName("debug") {
            storeFile = file(System.getenv("NEXTEND_KEYSTORE") ?: "${System.getProperty("user.home")}/.local/share/nextend/signing/install.keystore")
            check(storeFile!!.isFile) { "Restore the existing Nextend install.keystore before building; do not generate a new signing identity." }
            storePassword = System.getenv("NEXTEND_STORE_PASSWORD") ?: "android"
            keyAlias = System.getenv("NEXTEND_KEY_ALIAS") ?: "androiddebugkey"
            keyPassword = System.getenv("NEXTEND_KEY_PASSWORD") ?: "android"
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    buildTypes { release { isMinifyEnabled = false } }
}
dependencies { testImplementation("junit:junit:4.13.2") }

// Mountain Duck keeps historical sources beside live files; never compile them.
kotlin.sourceSets.all { kotlin.exclude("**/.duckversions/**") }
android.sourceSets.all { java.exclude("**/.duckversions/**") }
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    exclude("**/.duckversions/**")
}

// Keep transient compiler outputs off File Provider; canonical source and
// final artifacts stay in the project. Used by scripts/build-android.sh.
providers.gradleProperty("nextendBuildDir").orNull?.let { layout.buildDirectory.set(file(it)) }
