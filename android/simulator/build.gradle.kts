plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

kotlin { jvmToolchain(17) }

application {
    mainClass.set("com.mydroid.simulator.MainKt")
    applicationName = "simulator"
}

dependencies {
    implementation(project(":protocol"))
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    useJUnit()
    testLogging { events("passed", "failed", "skipped") }
}
