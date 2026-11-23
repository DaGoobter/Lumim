package com.huefin.desktop

import java.io.File

/** Where Huefin keeps things on this PC. (Named like the Android app object so shared code reads the same.) */
object HuefinApp {
    val instance get() = this
    val home: File = File(System.getenv("LOCALAPPDATA") ?: System.getProperty("user.home"), "Huefin").apply { mkdirs() }
    val cacheDir: File = File(home, "cache").apply { mkdirs() }
    val filesDir: File = File(home, "data").apply { mkdirs() }
    /** Downloads go to Videos\Huefin so they're easy to find and back up. */
    val downloadsDir: File get() = File(System.getProperty("user.home"), "Videos/Huefin").apply { mkdirs() }
}
