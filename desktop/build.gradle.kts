import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm") version "2.1.0"
    kotlin("plugin.compose") version "2.1.0"
    kotlin("plugin.serialization") version "2.1.0"
    id("org.jetbrains.compose") version "1.7.3"
}

val appVersion = "0.3." + (System.getenv("GITHUB_RUN_NUMBER") ?: "0")

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt.coil3:coil-compose:3.0.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.0.4")
    implementation("uk.co.caprica:vlcj:4.8.3")
}

kotlin { jvmToolchain(17) }

tasks.register("writeVersion") {
    val out = layout.buildDirectory.file("generated/version/huefin-version.txt")
    outputs.file(out)
    doLast { out.get().asFile.apply { parentFile.mkdirs(); writeText(appVersion) } }
}
sourceSets.main { resources.srcDir(layout.buildDirectory.dir("generated/version")) }
tasks.named("processResources") { dependsOn("writeVersion") }

compose.desktop {
    application {
        mainClass = "com.huefin.desktop.MainKt"
        jvmArgs += listOf("-Dsun.java2d.uiScale.enabled=true")
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Exe)
            // VLC, fetched by the build, ships inside the app (appres/windows/vlc).
            appResourcesRootDir.set(project.layout.projectDirectory.dir("appres"))
            packageName = "Huefin"
            packageVersion = appVersion
            description = "Huefin for Jellyfin"
            vendor = "Huefin"
            modules("java.prefs", "java.net.http", "jdk.unsupported", "java.naming")
            windows {
                menu = true
                menuGroup = "Huefin"
                shortcut = true
                perUserInstall = true
                dirChooser = false
                upgradeUuid = "6b0f2c1e-5a8d-4c2e-9b7a-1f3e8d2c4a71"
                iconFile.set(project.file("src/main/resources/huefin.ico"))
            }
        }
    }
}
