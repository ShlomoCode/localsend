import org.gradle.api.tasks.testing.Test

plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "org.localsend.localsend_app"
    compileSdk = 34
    defaultConfig { minSdk = 24 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isIncludeAndroidResources = true }
}
dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.13")
}
tasks.withType<Test>().configureEach {
    systemProperty("fixture.output", layout.buildDirectory.dir("fixture-evidence").get().asFile.absolutePath)
    testLogging { events("passed", "failed", "skipped"); showStandardStreams = true }
}
