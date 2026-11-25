package com.huefin.app.playback

import com.huefin.app.HuefinApp
import com.huefin.app.core.BaseItem
import com.huefin.app.core.DeviceProfile
import com.huefin.app.core.JellyfinClient
import com.huefin.app.core.MediaSource
import com.huefin.app.core.Prefs

/**
 * Who plays a video: Android's own player (ExoPlayer: HDR, Dolby Vision, best battery) or the
 * Huefin Engine (mpv + libplacebo), which plays nearly any file as-is, reshapes Dolby Vision Profile 5 and
 * tone-maps HDR for screens that can't show it, so the server doesn't have to convert anything.
 */
enum class PlaybackEngine(val label: String) {
    Auto("Automatic"), Apple("Android player only"), Prism("Huefin Engine always");
    companion object {
        // Same stored values as iOS ("auto", "apple", "prism") so server-pushed defaults apply to both.
        fun current(): PlaybackEngine = when (Prefs.string(Prefs.Keys.engine)) { "apple" -> Apple; "prism" -> Prism; else -> Auto }
        fun store(e: PlaybackEngine) = Prefs.set(Prefs.Keys.engine, when (e) { Auto -> "auto"; Apple -> "apple"; Prism -> "prism" })
    }
}

data class Playability(val kind: Kind, val detail: String) {
    enum class Kind { Original, Repackaged, HuefinEngine, Converted, Unknown }
    val title: String get() = when (kind) {
        Kind.Original -> "Plays original"; Kind.Repackaged -> "Plays original quality"
        Kind.HuefinEngine -> "Plays original with Huefin Engine"; Kind.Converted -> "Server converts"; Kind.Unknown -> "Checking…"
    }
}

object EngineDecider {
    private val fixable = setOf(
        "ContainerNotSupported", "VideoCodecNotSupported", "AudioCodecNotSupported", "SubtitleCodecNotSupported",
        "VideoProfileNotSupported", "VideoLevelNotSupported", "AudioChannelsNotSupported", "AudioProfileNotSupported",
        "VideoRangeTypeNotSupported", "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported", "VideoCodecTagNotSupported",
        "AudioSampleRateNotSupported", "AudioBitDepthNotSupported", "UnknownVideoStreamInfo", "UnknownAudioStreamInfo",
        "VideoFramerateNotSupported", "VideoBitDepthNotSupported", "RefFramesNotSupported", "VideoResolutionNotSupported",
    )

    fun reasons(src: MediaSource): List<String> {
        val t = src.transcodingUrl ?: return emptyList()
        val q = t.substringAfter("?", "")
        val raw = q.split("&").firstOrNull { it.substringBefore("=").equals("TranscodeReasons", true) }?.substringAfter("=") ?: ""
        return java.net.URLDecoder.decode(raw, "UTF-8").split(",").map { it.trim() }.filter { it.isNotEmpty() }
    }

    fun friendly(r: String) = when (r) {
        "ContainerNotSupported" -> "file type"
        "VideoCodecNotSupported", "VideoCodecTagNotSupported" -> "video format"
        "AudioCodecNotSupported", "AudioProfileNotSupported" -> "audio format"
        "SubtitleCodecNotSupported" -> "subtitles"
        "VideoRangeTypeNotSupported" -> "HDR type"
        "AudioChannelsNotSupported" -> "surround channels"
        "ContainerBitrateExceedsLimit", "VideoBitrateNotSupported", "AudioBitrateNotSupported" -> "too big for your quality limit"
        "VideoProfileNotSupported", "VideoLevelNotSupported", "VideoBitDepthNotSupported" -> "video profile"
        "VideoResolutionNotSupported" -> "resolution"
        else -> r.replace("NotSupported", "").lowercase()
    }

    fun profile(maxBitrate: Int) = DeviceProfile.build(HuefinApp.instance, maxBitrate)

    suspend fun playability(item: BaseItem, c: JellyfinClient, maxBitrate: Int, mediaSourceId: String? = null): Playability {
        val info = runCatching { c.playbackInfo(item.id, maxBitrate, profile(maxBitrate), subtitleStreamIndex = null, mediaSourceId = mediaSourceId) }.getOrNull()
            ?: return Playability(Playability.Kind.Unknown, "")
        val src = info.mediaSources.firstOrNull { it.id == mediaSourceId } ?: info.mediaSources.firstOrNull() ?: return Playability(Playability.Kind.Unknown, "")
        info.playSessionId?.let { c.stopEncoding(it) }
        if (src.supportsDirectPlay == true) return Playability(Playability.Kind.Original, "Streams the file untouched.")
        if (src.supportsDirectStream == true) return Playability(Playability.Kind.Repackaged, "Same picture and sound, just repackaged on the fly (light work for the server).")
        val why = reasons(src)
        val names = why.map(::friendly).toSortedSet().joinToString(", ")
        if (why.isNotEmpty() && why.all { it in fixable } && PlaybackEngine.current() != PlaybackEngine.Apple)
            return Playability(Playability.Kind.HuefinEngine, "Android's player can't handle the $names, so Huefin plays it with its own engine instead of making the server convert it.")
        return Playability(Playability.Kind.Converted, if (names.isEmpty()) "The server converts it for this device." else "Because of the $names.")
    }

    suspend fun useEngine(req: PlaybackRequest, c: JellyfinClient?, maxBitrate: Int): Boolean {
        val mode = PlaybackEngine.current()
        if (mode == PlaybackEngine.Apple || req.item.isLiveChannel || req.item.isAudio) return false
        req.localPath?.let { path ->
            val ext = path.substringAfterLast('.', "").lowercase()
            return mode == PlaybackEngine.Prism || ext !in setOf("mp4", "m4v", "mov", "mkv", "webm", "ts", "")
        }
        if (c == null) return false
        if (mode == PlaybackEngine.Prism) return true
        return playability(req.item, c, maxBitrate, req.mediaSourceId).kind == Playability.Kind.HuefinEngine
    }
}
