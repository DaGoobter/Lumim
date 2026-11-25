package com.huefin.desktop.player

import com.sun.jna.Library
import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.NativeLibrary
import com.sun.jna.Pointer
import java.io.File
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/** The parts of libmpv's C API Huefin uses (client.h). */
@Suppress("FunctionName")
interface MpvApi : Library {
    fun mpv_create(): Pointer?
    fun mpv_initialize(ctx: Pointer): Int
    fun mpv_terminate_destroy(ctx: Pointer)
    fun mpv_set_option_string(ctx: Pointer, name: String, data: String): Int
    fun mpv_set_property_string(ctx: Pointer, name: String, data: String): Int
    fun mpv_get_property_string(ctx: Pointer, name: String): Pointer?
    fun mpv_get_property(ctx: Pointer, name: String, format: Int, data: Pointer): Int
    fun mpv_command(ctx: Pointer, args: Array<String?>): Int
    fun mpv_free(data: Pointer)
    fun mpv_wait_event(ctx: Pointer, timeout: Double): Pointer
    fun mpv_error_string(error: Int): String

    companion object {
        const val FORMAT_FLAG = 3
        const val FORMAT_INT64 = 4
        const val FORMAT_DOUBLE = 5
        const val EVENT_NONE = 0
        const val EVENT_SHUTDOWN = 1
        const val EVENT_END_FILE = 7
        const val EVENT_FILE_LOADED = 8
        const val EVENT_VIDEO_RECONFIG = 17
        const val EVENT_PLAYBACK_RESTART = 21
        const val END_EOF = 0
        const val END_ERROR = 4

        @Volatile private var api: MpvApi? = null
        var loadError: String? = null; private set

        /** libmpv ships inside Huefin (app resources/mpv); a libmpv-2.dll on PATH works too. */
        fun get(): MpvApi? {
            api?.let { return it }
            return try {
                val res = System.getProperty("compose.application.resources.dir")
                res?.let { File(it, "mpv") }?.takeIf { File(it, "libmpv-2.dll").exists() }?.let {
                    NativeLibrary.addSearchPath("libmpv-2", it.absolutePath)
                }
                Native.load("libmpv-2", MpvApi::class.java, mapOf(Library.OPTION_STRING_ENCODING to "UTF-8")).also { api = it }
            } catch (t: Throwable) {
                loadError = "Couldn't start the Huefin Engine (${t.message}). Reinstall Huefin to fix it."
                null
            }
        }
    }
}

/**
 * One mpv player. Every call is thread-safe; events arrive on mpv's own thread through [onEvent].
 * mpv is shut down from its event thread, so nothing ever touches it after it's gone.
 */
class Mpv private constructor(private val api: MpvApi, private val h: Pointer) {
    private val lock = ReentrantReadWriteLock()
    @Volatile private var alive = true
    /** (event id, end-file reason or -1, mpv error code). Called on mpv's thread. */
    var onEvent: (Int, Int, Int) -> Unit = { _, _, _ -> }

    companion object {
        fun create(options: Map<String, String>): Mpv? {
            val api = MpvApi.get() ?: return null
            val h = api.mpv_create() ?: return null
            options.forEach { (k, v) -> api.mpv_set_option_string(h, k, v) }
            if (api.mpv_initialize(h) < 0) { api.mpv_terminate_destroy(h); return null }
            return Mpv(api, h).also { it.startEvents() }
        }
    }

    private fun startEvents() {
        Thread({
            while (true) {
                val ev = api.mpv_wait_event(h, 1.0)
                val id = ev.getInt(0)
                if (id == MpvApi.EVENT_NONE) continue
                if (id == MpvApi.EVENT_SHUTDOWN) break
                var reason = -1; var err = 0
                if (id == MpvApi.EVENT_END_FILE) ev.getPointer(16)?.let { d -> reason = d.getInt(0); err = d.getInt(4) }
                runCatching { onEvent(id, reason, err) }
            }
            lock.write { alive = false; api.mpv_terminate_destroy(h) }
        }, "huefin-mpv-events").apply { isDaemon = true; start() }
    }

    private inline fun <T> use(fallback: T, block: () -> T): T = lock.read { if (alive) block() else fallback }

    fun command(vararg args: String) = use(-1) { api.mpv_command(h, arrayOf(*args, null)) }
    fun set(name: String, value: String) = use(-1) { api.mpv_set_property_string(h, name, value) }
    fun string(name: String): String? = use(null) {
        api.mpv_get_property_string(h, name)?.let { p -> p.getString(0, "UTF-8").also { api.mpv_free(p) } }
    }
    fun double(name: String): Double? = use(null) {
        val m = Memory(8)
        if (api.mpv_get_property(h, name, MpvApi.FORMAT_DOUBLE, m) >= 0) m.getDouble(0) else null
    }
    fun long(name: String): Long? = use(null) {
        val m = Memory(8)
        if (api.mpv_get_property(h, name, MpvApi.FORMAT_INT64, m) >= 0) m.getLong(0) else null
    }
    fun flag(name: String): Boolean = use(false) {
        val m = Memory(4)
        api.mpv_get_property(h, name, MpvApi.FORMAT_FLAG, m) >= 0 && m.getInt(0) != 0
    }
    fun errorText(code: Int): String = runCatching { api.mpv_error_string(code) }.getOrDefault("error $code")

    /** Asks mpv to quit; its event thread finishes the shutdown. */
    fun destroy() { if (alive) command("quit") }
}
