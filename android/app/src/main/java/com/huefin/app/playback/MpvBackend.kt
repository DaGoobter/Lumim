package com.huefin.app.playback

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import com.huefin.app.core.DeviceProfile
import dev.jdtech.mpv.MPVLib

/**
 * The Huefin Engine (mpv + libplacebo + FFmpeg): plays nearly any file straight from the original.
 *
 * It picks one of two picture paths for each video:
 * - **HDR passthrough**: the phone's own decoder draws straight onto the screen, so an HDR screen shows real
 *   HDR10 / HDR10+ / HLG (and the HDR10 layer of Dolby Vision), exactly like Android's player would.
 * - **Accurate rendering**: libplacebo draws the picture. It reshapes Dolby Vision Profile 5 into its true
 *   colours (no purple and green) and tone-maps HDR properly for screens that can't show HDR.
 */
class MpvBackend(context: Context) : Backend {
    override val name = "Huefin Engine"
    override var onEnded: () -> Unit = {}
    override var onError: (String) -> Unit = {}
    override var onReady: () -> Unit = {}
    override val supportsBoost = true

    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    // If mpv takes the app down while starting, the next launch switches the engine off (see CrashReport).
    private val breadcrumb = com.huefin.app.core.CrashReport.engineStarting(true)
    private val mpv: MPVLib = MPVLib.create(app) ?: throw IllegalStateException("The Huefin Engine couldn't start on this device.")
    private var surfaceAttached = false
    private var pending: (() -> Unit)? = null
    private var externalSubs: List<SubtitleSource> = emptyList()
    private var readySent = false
    private var released = false

    @Volatile private var timePos = 0.0
    @Volatile private var durationS = 0.0
    @Volatile private var paused = false
    @Volatile private var cacheWait = false
    @Volatile private var seeking = false
    @Volatile private var loaded = false
    @Volatile private var subText: String? = null

    private var rangeType: String? = null
    private var codec: String? = null
    /** "passthrough" or "accurate", for the info panel. */
    var pictureMode = "accurate"; private set

    /** A file was open when a new one was asked for; mpv reports that old file's end first, which isn't an error. */
    @Volatile private var ignoreNextEnd = false

    private val observer = object : MPVLib.EventObserver {
        override fun eventProperty(property: String, value: Double) {
            when (property) { "time-pos" -> timePos = value; "duration" -> durationS = value }
        }
        override fun eventProperty(property: String, value: Boolean) {
            when (property) {
                "pause" -> paused = value; "paused-for-cache" -> cacheWait = value; "seeking" -> seeking = value
                "eof-reached" -> if (value && loaded) main.post { onEnded() }
            }
        }
        override fun eventProperty(property: String, value: Long) {}
        override fun eventProperty(property: String, value: String) { if (property == "sub-text") subText = value.ifBlank { null } }
        override fun eventProperty(property: String) { if (property == "sub-text") subText = null }
        override fun event(eventId: Int) {
            when (eventId) {
                MPV_EVENT_FILE_LOADED -> main.post { loaded = true; addExternalSubs() }
                MPV_EVENT_PLAYBACK_RESTART -> main.post {
                    if (!readySent) { readySent = true; com.huefin.app.core.CrashReport.engineStarting(false); onReady() }
                }
                // With keep-open, a file that finishes stays open (eof-reached), so an end here is a stop or a failure.
                MPV_EVENT_END_FILE -> main.post {
                    if (ignoreNextEnd) ignoreNextEnd = false
                    else if (!loaded && !released) onError("The Huefin Engine couldn't open this file.")
                }
            }
        }
    }

    init {
        val o = mapOf(
            "vo" to "gpu-next", "gpu-context" to "android", "opengl-es" to "yes",
            "hwdec" to "mediacodec-copy", "hwdec-codecs" to "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1",
            "ao" to "audiotrack,opensles", "audio-channels" to "auto-safe",
            "tone-mapping" to "auto", "hdr-compute-peak" to "auto", "target-colorspace-hint" to "no",
            "cache" to "yes", "demuxer-max-bytes" to "150MiB", "demuxer-max-back-bytes" to "50MiB", "demuxer-readahead-secs" to "30",
            "network-timeout" to "30", "user-agent" to "Huefin for Android",
            "volume-max" to "200", "keep-open" to "yes", "msg-level" to "all=warn", "idle" to "yes", "force-window" to "no",
            "input-default-bindings" to "no", "input-vo-keyboard" to "no", "osd-level" to "0",
            "sub-ass-override" to "no", "sub-scale-with-window" to "yes", "sub-use-margins" to "yes",
            "save-position-on-quit" to "no", "ytdl" to "no",
        )
        o.forEach { (k, v) -> mpv.setOptionString(k, v) }
        passthroughCodecs(app).takeIf { it.isNotEmpty() }?.let { mpv.setOptionString("audio-spdif", it.joinToString(",")) }
        mpv.init()
        mpv.addObserver(observer)
        listOf("time-pos" to MPVLib.MpvFormat.MPV_FORMAT_DOUBLE, "duration" to MPVLib.MpvFormat.MPV_FORMAT_DOUBLE,
            "pause" to MPVLib.MpvFormat.MPV_FORMAT_FLAG, "paused-for-cache" to MPVLib.MpvFormat.MPV_FORMAT_FLAG,
            "seeking" to MPVLib.MpvFormat.MPV_FORMAT_FLAG, "sub-text" to MPVLib.MpvFormat.MPV_FORMAT_STRING,
            "eof-reached" to MPVLib.MpvFormat.MPV_FORMAT_FLAG,
        ).forEach { (p, f) -> mpv.observeProperty(p, f) }
    }

    override fun setVideoHint(rangeType: String?, codec: String?) { this.rangeType = rangeType; this.codec = codec }

    /** Chooses the picture path for this file (see the class comment). */
    private fun configurePicture() {
        val caps = DeviceProfile.capabilities(app)
        val r = rangeType ?: ""
        val c = (codec ?: "").lowercase()
        val hdrScreen = caps.hdr10 || caps.hdr10Plus || caps.hlg
        val hasDecoder = when (c) { "hevc", "h265" -> caps.hevc; "av1" -> caps.av1; "vp9" -> caps.vp9; else -> false }
        val profile5 = r == "DOVI"   // Dolby Vision with no HDR10 layer: only libplacebo gets its colours right
        val hdrBase = r.startsWith("HDR10") || r == "HLG" || r == "DOVIWithHDR10" || r == "DOVIWithHDR10Plus" || r == "DOVIWithHLG" || r == "DOVIWithEL"
        val screenTakesIt = when {
            r == "HLG" || r == "DOVIWithHLG" -> caps.hlg || caps.hdr10
            else -> caps.hdr10 || caps.hdr10Plus
        }
        if (hdrScreen && hdrBase && screenTakesIt && hasDecoder) {
            pictureMode = "passthrough"
            mpv.setPropertyString("hwdec", "mediacodec")
            setVo("mediacodec_embed")
        } else {
            pictureMode = "accurate"
            // Profile 5's reshaping data comes from FFmpeg's own decoder, so decode it in software.
            mpv.setPropertyString("hwdec", if (profile5) "no" else "mediacodec-copy")
            setVo("gpu-next")
        }
    }
    private var vo = "gpu-next"
    private fun setVo(v: String) { vo = v; if (surfaceAttached) mpv.setPropertyString("vo", v) }

    override fun createView(context: Context): View = SurfaceView(context).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) {
                if (released) return
                mpv.attachSurface(h.surface)
                surfaceAttached = true
                mpv.setOptionString("force-window", "yes")
                mpv.setPropertyString("vo", vo)
                pending?.invoke(); pending = null
            }
            override fun surfaceChanged(h: SurfaceHolder, format: Int, w: Int, hgt: Int) {
                if (!released) mpv.setPropertyString("android-surface-size", "${w}x$hgt")
            }
            override fun surfaceDestroyed(h: SurfaceHolder) {
                if (released || !surfaceAttached) return
                surfaceAttached = false
                mpv.setPropertyString("vo", "null")
                mpv.setOptionString("force-window", "no")
                mpv.detachSurface()
            }
        })
    }

    override fun prepare(url: String, startMs: Long, subtitles: List<SubtitleSource>, hls: Boolean) {
        ignoreNextEnd = loaded
        readySent = false; loaded = false; externalSubs = subtitles
        timePos = startMs / 1000.0
        val go = {
            configurePicture()
            mpv.setPropertyString("start", if (startMs > 0) "%.3f".format(java.util.Locale.US, startMs / 1000.0) else "none")
            mpv.command(arrayOf("loadfile", url, "replace"))
            mpv.setPropertyBoolean("pause", false)
        }
        if (surfaceAttached) go() else pending = go
    }

    private fun addExternalSubs() {
        externalSubs.forEach { s -> runCatching { mpv.command(arrayOf("sub-add", s.url, "auto", s.label, s.language ?: "")) } }
    }

    override fun play() { mpv.setPropertyBoolean("pause", false) }
    override fun pause() { mpv.setPropertyBoolean("pause", true) }
    override fun seekTo(ms: Long) { timePos = ms / 1000.0; mpv.command(arrayOf("seek", "%.3f".format(java.util.Locale.US, ms / 1000.0), "absolute")) }
    override val positionMs get() = (timePos * 1000).toLong().coerceAtLeast(0)
    override val durationMs get() = (durationS * 1000).toLong().coerceAtLeast(0)
    override val isPlaying get() = loaded && !paused && !cacheWait
    override val isBuffering get() = !loaded || cacheWait || seeking
    override fun setSpeed(speed: Float) { mpv.setPropertyDouble("speed", speed.toDouble()) }

    private fun tracks(type: String): List<Track> {
        val n = mpv.getPropertyInt("track-list/count") ?: 0
        return (0 until n).mapNotNull { i ->
            if (mpv.getPropertyString("track-list/$i/type") != type) return@mapNotNull null
            val id = mpv.getPropertyInt("track-list/$i/id") ?: return@mapNotNull null
            val lang = mpv.getPropertyString("track-list/$i/lang")?.let { l -> java.util.Locale(l).displayLanguage.takeIf { it.isNotBlank() } ?: l }
            val channels = if (type == "audio") mpv.getPropertyInt("track-list/$i/demux-channel-count")?.takeIf { it > 0 }?.let { ch ->
                when (ch) { 1 -> "Mono"; 2 -> "Stereo"; 6 -> "5.1"; 8 -> "7.1"; else -> "${ch}ch" } } else null
            val codecName = mpv.getPropertyString("track-list/$i/codec")?.uppercase()?.replace("PGSSUB", "PGS")?.replace("SUBRIP", "SRT")
            val forced = if (mpv.getPropertyBoolean("track-list/$i/forced") == true) "Forced" else null
            val label = listOfNotNull(mpv.getPropertyString("track-list/$i/title"), lang, codecName, channels, forced).distinct()
                .joinToString(" · ").ifEmpty { if (type == "audio") "Track $id" else "Subtitles $id" }
            Track(id.toString(), label, mpv.getPropertyBoolean("track-list/$i/selected") == true)
        }
    }
    override fun audioTracks() = tracks("audio")
    override fun subtitleTracks() = tracks("sub")
    override fun selectAudio(id: String) { mpv.setPropertyString("aid", id) }
    override fun selectSubtitle(id: String?) { mpv.setPropertyString("sid", id ?: "no") }
    override fun setFill(fill: Boolean) { mpv.setPropertyDouble("panscan", if (fill) 1.0 else 0.0) }
    override fun setVolumeBoost(percent: Int) { mpv.setPropertyInt("volume", percent.coerceIn(0, 200)) }
    /** In HDR passthrough the decoder owns the screen, so Huefin draws text subtitles itself. */
    override val overlaySubtitle: String? get() = if (pictureMode == "passthrough") subText else null
    override val detail: String get() = if (pictureMode == "passthrough") "HDR passthrough" else "Accurate colour (libplacebo)"

    override fun release() {
        if (released) return
        released = true
        com.huefin.app.core.CrashReport.engineStarting(false)
        pending = null
        runCatching { mpv.removeObserver(observer) }
        runCatching { if (surfaceAttached) { mpv.setPropertyString("vo", "null"); mpv.detachSurface() } }
        surfaceAttached = false
        val m = mpv
        // Tearing mpv down can take a moment; never on the main thread.
        Thread { runCatching { m.command(arrayOf("stop")); m.destroy() } }.start()
    }

    companion object {
        // mpv's event numbers (client.h); spelled out because this libmpv build doesn't name them.
        private const val MPV_EVENT_END_FILE = 7
        private const val MPV_EVENT_FILE_LOADED = 8
        private const val MPV_EVENT_PLAYBACK_RESTART = 21

        /** Surround formats the connected receiver or TV says it can decode itself (HDMI / ARC / eARC). */
        fun passthroughCodecs(context: Context): List<String> {
            val am = context.getSystemService(AudioManager::class.java) ?: return emptyList()
            val hdmi = buildSet {
                add(AudioDeviceInfo.TYPE_HDMI); add(AudioDeviceInfo.TYPE_HDMI_ARC)
                if (Build.VERSION.SDK_INT >= 31) add(AudioDeviceInfo.TYPE_HDMI_EARC)
            }
            val enc = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.type in hdmi }.flatMap { it.encodings.toList() }.toSet()
            return buildList {
                if (AudioFormat.ENCODING_AC3 in enc) add("ac3")
                if (AudioFormat.ENCODING_E_AC3 in enc) add("eac3")
                if (AudioFormat.ENCODING_DTS in enc) add("dts")
                if (AudioFormat.ENCODING_DTS_HD in enc) add("dts-hd")
                if (AudioFormat.ENCODING_DOLBY_TRUEHD in enc) add("truehd")
            }
        }
    }
}
