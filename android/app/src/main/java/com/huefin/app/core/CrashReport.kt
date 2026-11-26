package com.huefin.app.core

import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File

/**
 * Catches crashes so testers can send them: Kotlin/Java crashes are written down as they happen, and crashes inside
 * native code (the video engines) are read back from Android on the next launch (Android 11+).
 *
 * Also protects playback: if the app died while the Huefin Engine was starting a video, the engine is switched off
 * so the next video uses Android's player instead of crashing again.
 */
object CrashReport {
    private const val FILE = "last-crash.txt"
    private const val SEEN = "crash.seenExit"
    const val ENGINE_STARTING = "engine.starting"
    const val ENGINE_OFF_AFTER_CRASH = "engine.offAfterCrash"

    /** Marks the engine as starting (written to disk at once, so it survives a native crash). */
    fun engineStarting(on: Boolean) { Prefs.sp.edit().putBoolean(ENGINE_STARTING, on).commit() }
    private lateinit var app: Application
    private const val TRAIL = "crash-trail.txt"

    /** Records what the app was doing (the last 40 steps survive a crash, so a report says where it happened). */
    fun step(what: String) {
        runCatching {
            val f = File(app.filesDir, TRAIL)
            val lines = (if (f.exists()) f.readLines().takeLast(39) else emptyList()) +
                (java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US).format(java.util.Date()) + "  " + what)
            f.writeText(lines.joinToString("\n"))
        }
    }
    private fun trail(): String = runCatching { File(app.filesDir, TRAIL).readText() }.getOrDefault("(none)")

    fun install(a: Application) {
        app = a
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching { File(a.filesDir, FILE).writeText(header() + "Thread: ${t.name}\n\n" + e.stackTraceToString() + "\n\nLast steps:\n" + trail()) }
            previous?.uncaughtException(t, e)
        }
        if (Prefs.bool(ENGINE_STARTING)) {
            Prefs.set(ENGINE_STARTING, false)
            Prefs.set(ENGINE_OFF_AFTER_CRASH, true)
        }
        if (Build.VERSION.SDK_INT >= 30) runCatching {
            val exits = a.getSystemService(ActivityManager::class.java).getHistoricalProcessExitReasons(null, 0, 3)
            val last = exits.firstOrNull() ?: return@runCatching
            val seen = Prefs.string(SEEN)?.toLongOrNull() ?: 0L
            if (last.timestamp <= seen) return@runCatching
            Prefs.set(SEEN, last.timestamp.toString())
            val bad = setOf(ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR)
            if (last.reason !in bad) return@runCatching
            val f = File(a.filesDir, FILE)
            val javaTrace = if (f.exists() && f.lastModified() >= last.timestamp - 10_000) "\n\n--- Java crash ---\n" + f.readText() else ""
            val kind = when (last.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash (inside a video engine or system library)"
                ApplicationExitInfo.REASON_ANR -> "Froze (not responding)"
                else -> "Crash"
            }
            val history = exits.joinToString("\n") { e ->
                "  ${java.util.Date(e.timestamp)} · reason ${e.reason} · status ${e.status} · ${e.description ?: "-"} · ${e.processName}"
            }
            val anr = if (last.reason == ApplicationExitInfo.REASON_ANR)
                runCatching { last.traceInputStream?.bufferedReader()?.readText()?.take(6000) }.getOrNull() ?: "" else ""
            f.writeText(header() + "$kind: ${last.description ?: "-"}\n" +
                "Engine was starting: ${Prefs.bool(ENGINE_OFF_AFTER_CRASH)}\n\nRecent exits:\n$history\n\nLast steps:\n${trail()}" +
                javaTrace + (if (anr.isNotEmpty()) "\n\n--- Threads ---\n$anr" else ""))
        }
    }

    private fun header(): String {
        val v = runCatching { app.packageManager.getPackageInfo(app.packageName, 0) }.getOrNull()
        return "Huefin ${v?.versionName} (build ${if (Build.VERSION.SDK_INT >= 28) v?.longVersionCode else 0})\n" +
            "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})\n" +
            "${java.util.Date()}\n\n"
    }

    /** Something that didn't crash the app but should be reported (e.g. the engine failing to load). */
    fun note(what: String, e: Throwable) {
        runCatching { File(app.filesDir, FILE).writeText(header() + what + "\n\n" + e.stackTraceToString()) }
    }

    fun pending(): String? = runCatching { File(app.filesDir, FILE).takeIf { it.exists() }?.readText() }.getOrNull()
    fun clear() { runCatching { File(app.filesDir, FILE).delete() } }
}

/** Shown once after a crash: the details, a Copy button, and (if it happened) a way to turn the engine back on. */
@Composable
fun CrashReportDialog() {
    var report by remember { mutableStateOf(CrashReport.pending()) }
    val text = report ?: return
    val ctx = LocalContext.current
    val engineOff = Prefs.bool(CrashReport.ENGINE_OFF_AFTER_CRASH)
    AlertDialog(
        onDismissRequest = { CrashReport.clear(); report = null },
        title = { Text("Huefin crashed last time") },
        text = {
            androidx.compose.foundation.layout.Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text(if (engineOff) "It happened while the Huefin Engine was starting a video, so videos will use Android's player for now. Copy this and send it over so it can be fixed:\n"
                     else "Copy this and send it over so it can be fixed:\n")
                Text(text, fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp)
            }
        },
        confirmButton = {
            TextButton({
                ctx.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Huefin crash", text))
                CrashReport.clear(); report = null
            }) { Text("Copy") }
        },
        dismissButton = {
            if (engineOff) TextButton({ Prefs.set(CrashReport.ENGINE_OFF_AFTER_CRASH, false); CrashReport.clear(); report = null }) { Text("Turn engine back on") }
            else TextButton({ CrashReport.clear(); report = null }) { Text("Close") }
        },
    )
}

