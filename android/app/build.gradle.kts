plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dev.padbridge"
    compileSdk = 36
    defaultConfig { applicationId = "dev.padbridge"; minSdk = 30; targetSdk = 36; versionCode = 4; versionName = "0.4.0" }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    buildTypes { release { isMinifyEnabled = false } }
}
dependencies { testImplementation("junit:junit:4.13.2") }
