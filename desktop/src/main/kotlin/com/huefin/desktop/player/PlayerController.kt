package com.huefin.desktop.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.MediaSegment
import com.huefin.desktop.core.Prefs
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

data class TrackChoice(val id: Int, val label: String)
/** A track as the shared track-preference code sees it. */
data class Track(val id: String, val label: String, val selected: Boolean, val language: String? = null)

/**
 * Plays one item (and the next episodes) in the Huefin Engine (mpv + libplacebo, drawing with Direct3D 11 into
 * the player window), reports progress to the server, skips intros and credits.
 *
 * Picture: with Windows HDR on, HDR10 / HDR10+ / HLG go to the screen as real HDR; with it off they're tone-mapped
 * properly. Dolby Vision is reshaped from its own metadata (true colours for Profile 5, the DV grade for 7 and 8).
 */
class PlayerController(start: BaseItem, private val startTicks: Long, val onClose: () -> Unit) {
    companion object { var active: PlayerController? = null }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val client: JellyfinClient? = AppState.client
    private var mp: Mpv? = null
    private val hwnd = CompletableDeferred<Long>()
    /** The native window mpv draws into, from [com.huefin.desktop.ui.PlayerScreen]. */
    fun attachWindow(handle: Long) { hwnd.complete(handle) }
    private var pendingSubs = listOf<Triple<String, String, String>>()
    private var restarted = false
    /** How the picture is being drawn ("HDR10 → HDR (PQ) · hardware decode"). */
    var pictureInfo by mutableStateOf(""); private set

    var item by mutableStateOf(start); private set
    var playing by mutableStateOf(false); private set
    var loading by mutableStateOf(true); private set
    var error by mutableStateOf<String?>(null); private set
    var positionMs by mutableStateOf(0L); private set
    var lengthMs by mutableStateOf(0L); private set
    var volume by mutableStateOf(100); private set
    var muted by mutableStateOf(false); private set
    var audioTracks by mutableStateOf<List<TrackChoice>>(emptyList()); private set
    var subtitleTracks by mutableStateOf<List<TrackChoice>>(emptyList()); private set
    var audioTrack by mutableStateOf(-1); private set
    var subtitleTrack by mutableStateOf(-1); private set
    var segments by mutableStateOf<List<MediaSegment>>(emptyList()); private set
    var nextEpisode by mutableStateOf<BaseItem?>(null); private set
    var upNextIn by mutableStateOf<Int?>(null); private set
    var method by mutableStateOf(""); private set

    val isLive get() = item.isLiveChannel
    val isPlaying get() = playing
    val positionTicks get() = positionMs * 10_000
    private var playSessionId: String? = null
    private var mediaSourceId: String? = null
    private var liveStreamId: String? = null
    private var reportedStart = false
    private var lastReport = 0L
    private var ticker: Job? = null
    private var upNextDismissed = false
    private val skipped = mutableSetOf<Double>()
    private var closed = false

    fun start() {
        active = this
        scope.launch {
            val wid = hwnd.await()
            val passthrough = Prefs.bool(Prefs.Keys.passthrough)
            val p = Mpv.create(buildMap {
                put("wid", wid.toString())
                put("vo", "gpu-next"); put("gpu-api", "d3d11"); put("hwdec", "d3d11va"); put("hwdec-codecs", "all")
                // HDR straight to the screen when Windows HDR is on; libplacebo tone-maps it otherwise.
                put("target-colorspace-hint", "yes"); put("tone-mapping", "auto"); put("hdr-compute-peak", "auto"); put("gamut-mapping-mode", "auto")
                put("keep-open", "no"); put("idle", "yes"); put("force-window", "yes")
                put("input-default-bindings", "no"); put("input-vo-keyboard", "no"); put("input-cursor", "no"); put("input-cursor-passthrough", "yes")
                put("cursor-autohide", "no"); put("osc", "no"); put("osd-level", "0"); put("terminal", "no"); put("msg-level", "all=warn")
                put("cache", "yes"); put("demuxer-max-bytes", "300MiB"); put("demuxer-max-back-bytes", "100MiB"); put("demuxer-readahead-secs", "30")
                put("network-timeout", "30"); put("user-agent", "Huefin for Windows"); put("ytdl", "no")
                put("volume-max", "200"); put("audio-channels", "auto")
                if (passthrough) { put("audio-spdif", "ac3,eac3,dts,dts-hd,truehd"); put("audio-exclusive", "yes") }
                put("sub-ass-override", "no"); put("sub-scale-with-window", "yes"); put("sub-use-margins", "yes")
            }) ?: run { error = MpvApi.loadError ?: "Couldn't start the Huefin Engine."; loading = false; return@launch }
            p.onEvent = { id, reason, err -> scope.launch { onMpvEvent(id, reason, err) } }
            mp = p
            if (closed) { p.destroy(); return@launch }
            load(item, startTicks); SyncPlay.playerOpened(this@PlayerController)
        }
        ticker = scope.launch {
            while (isActive) {
                mp?.let { m ->
                    m.double("time-pos")?.let { positionMs = (it * 1000).toLong().coerceAtLeast(0) }
                    m.double("duration")?.takeIf { it > 0 }?.let { lengthMs = (it * 1000).toLong() }
                    val was = playing
                    playing = restarted && !m.flag("pause") && !m.flag("core-idle")
                    if (restarted) loading = m.flag("paused-for-cache") || m.flag("seeking") && !playing
                    if (was && !playing) report("Sessions/Playing/Progress", true)
                }
                report("Sessions/Playing/Progress")
                autoSkip(); upNext()
                delay(250)
            }
        }
    }

    private fun onMpvEvent(id: Int, reason: Int, err: Int) {
        val p = mp ?: return
        when (id) {
            MpvApi.EVENT_FILE_LOADED -> {
                pendingSubs.forEach { (u, title, lang) -> p.command("sub-add", u, "auto", title, lang) }
                pendingSubs = emptyList()
            }
            MpvApi.EVENT_PLAYBACK_RESTART -> {
                restarted = true; loading = false; refreshTracks(); pictureInfo = describePicture(p)
            }
            MpvApi.EVENT_VIDEO_RECONFIG -> pictureInfo = describePicture(p)
            MpvApi.EVENT_END_FILE -> when (reason) {
                MpvApi.END_EOF -> onFinished()
                MpvApi.END_ERROR -> if (isLive) scope.launch { reload() } else { error = "This couldn't be played (${p.errorText(err)})."; loading = false }
            }
        }
    }

    private fun describePicture(m: Mpv): String {
        val src = when (m.string("video-params/gamma")) { "pq" -> "HDR10"; "hlg" -> "HLG"; null -> return ""; else -> "SDR" }
        val dst = when (m.string("video-target-params/gamma")) { "pq" -> "HDR"; "hlg" -> "HDR (HLG)"; else -> "SDR" }
        val hw = if ((m.string("hwdec-current") ?: "no") == "no") "software decode" else "hardware decode"
        return "$src → $dst${if (src != "SDR" && dst == "SDR") " (tone mapped)" else ""} · $hw"
    }

    private fun profile(): JsonObject = buildJsonObject {
        put("Name", "Huefin for Windows")
        put("MaxStreamingBitrate", AppState.maxBitrate)
        put("MaxStaticBitrate", 400_000_000)
        // VLC plays every container and codec, so the server always sends the original file.
        putJsonArray("DirectPlayProfiles") {
            add(buildJsonObject { put("Type", "Video") })
            add(buildJsonObject { put("Type", "Audio") })
        }
        putJsonArray("TranscodingProfiles") {
            add(buildJsonObject { put("Container", "ts"); put("Type", "Video"); put("VideoCodec", "h264,hevc"); put("AudioCodec", "aac,ac3,eac3,mp3")
                put("Protocol", "hls"); put("Context", "Streaming"); put("MaxAudioChannels", "6"); put("BreakOnNonKeyFrames", false) })
            add(buildJsonObject { put("Container", "mp3"); put("Type", "Audio"); put("AudioCodec", "mp3"); put("Protocol", "http"); put("Context", "Streaming") })
        }
        putJsonArray("SubtitleProfiles") {
            listOf("srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgssub", "dvdsub", "dvbsub", "mov_text", "ttml").forEach {
                add(buildJsonObject { put("Format", it); put("Method", "Embed") })
            }
        }
        putJsonArray("CodecProfiles") {}
        putJsonArray("ContainerProfiles") {}
        putJsonObject("DirectPlayOptions") {}
    }

    private fun open(url: String, ticks: Long) {
        val p = mp ?: return
        restarted = false
        p.set("start", if (ticks > 0) "%.3f".format(java.util.Locale.US, ticks / 10_000_000.0) else "none")
        p.command("loadfile", url, "replace")
        p.set("pause", "no")
    }

    private suspend fun load(target: BaseItem, ticks: Long) {
        if (mp == null) return
        loading = true; error = null; reportedStart = false; upNextDismissed = false; upNextIn = null; skipped.clear(); tracksApplied = false
        pictureInfo = ""
        com.huefin.desktop.downloads.DownloadManager.localFile(target.id)?.let { f ->
            method = "Downloaded (offline)"; item = target; mediaSourceId = null; playSessionId = null; liveStreamId = null
            pendingSubs = emptyList()
            open(f.absolutePath, ticks)
            lengthMs = (target.runTimeTicks ?: 0) / 10_000
            client?.let { c -> runCatching { segments = c.mediaSegments(target.id); nextEpisode = if (target.type == "Episode") c.episodeAfter(target) else null } }
            return
        }
        val c = client ?: run { error = "Not connected to your server."; return }
        val info = try {
            c.playbackInfo(target.id, if (target.isLiveChannel) AppState.maxBitrate.coerceAtMost(40_000_000) else AppState.maxBitrate, profile(), ticks)
        } catch (e: Exception) { error = e.message ?: "Couldn't start playback."; loading = false; return }
        val src = info.mediaSources.firstOrNull() ?: run { error = "Nothing playable in this item."; loading = false; return }
        playSessionId = info.playSessionId; mediaSourceId = src.id; liveStreamId = src.liveStreamId
        val url = when {
            target.isLiveChannel -> { method = "Live stream"
                src.transcodingUrl?.let { c.absoluteURL(it, live = true) } ?: c.liveHLSURL(target.id, src.id, src.liveStreamId, info.playSessionId, 40_000_000, true) }
            src.supportsDirectPlay == true || src.transcodingUrl == null -> { method = "Original file (Huefin Engine)"; c.directPlayURL(target.id, src.id, src.container) }
            else -> { method = "Server converts (your quality limit)"; c.absoluteURL(src.transcodingUrl) }
        }
        // Subtitle files kept next to the video on the server.
        pendingSubs = src.mediaStreams.orEmpty().filter { it.type == "Subtitle" && it.isExternal == true && it.index != null }.map { s ->
            val ext = when ((s.codec ?: "").lowercase()) { "ass", "ssa" -> "ass"; "vtt", "webvtt" -> "vtt"; else -> "srt" }
            Triple(c.url("Videos/${target.id}/${src.id}/Subtitles/${s.index}/0/Stream.$ext", mapOf("api_key" to c.accessToken)),
                s.displayTitle ?: s.title ?: s.language ?: "Subtitles", s.language ?: "")
        }
        open(url, if (target.isLiveChannel) 0 else ticks)
        item = target
        positionMs = ticks / 10_000; lengthMs = (target.runTimeTicks ?: 0) / 10_000
        segments = if (target.isLiveChannel) emptyList() else c.mediaSegments(target.id)
        nextEpisode = if (target.type == "Episode") c.episodeAfter(target) else null
    }

    private fun tracks(m: Mpv, type: String): List<Pair<TrackChoice, Boolean>> {
        val n = (m.long("track-list/count") ?: 0).toInt()
        return (0 until n).mapNotNull { i ->
            if (m.string("track-list/$i/type") != type) return@mapNotNull null
            val id = m.long("track-list/$i/id")?.toInt() ?: return@mapNotNull null
            val lang = m.string("track-list/$i/lang")?.let { l -> java.util.Locale.forLanguageTag(l).displayLanguage.ifBlank { l } }
            val ch = if (type == "audio") m.long("track-list/$i/demux-channel-count")?.takeIf { it > 0 }?.let {
                when (it.toInt()) { 1 -> "Mono"; 2 -> "Stereo"; 6 -> "5.1"; 8 -> "7.1"; else -> "${it}ch" } } else null
            val codec = m.string("track-list/$i/codec")?.uppercase()?.replace("PGSSUB", "PGS")?.replace("SUBRIP", "SRT")
            val forced = if (m.flag("track-list/$i/forced")) "Forced" else null
            val label = listOfNotNull(m.string("track-list/$i/title"), lang, codec, ch, forced).distinct().joinToString(" · ")
                .ifEmpty { if (type == "audio") "Track $id" else "Subtitles $id" }
            TrackChoice(id, label) to m.flag("track-list/$i/selected")
        }
    }

    private fun refreshTracks() {
        val p = mp ?: return
        val a = tracks(p, "audio"); val s = tracks(p, "sub")
        audioTracks = a.map { it.first }; subtitleTracks = s.map { it.first }
        audioTrack = a.firstOrNull { it.second }?.first?.id ?: -1
        subtitleTrack = s.firstOrNull { it.second }?.first?.id ?: -1
        if (!tracksApplied && audioTracks.isNotEmpty()) {
            tracksApplied = true
            val (au, sub) = com.huefin.desktop.core.TrackPrefs.choose(
                audioTracks.map { Track(it.id.toString(), it.label, it.id == audioTrack) },
                subtitleTracks.map { Track(it.id.toString(), it.label, it.id == subtitleTrack) })
            au?.toIntOrNull()?.let { selectAudio(it) }
            selectSubtitle(sub?.toIntOrNull() ?: -1)
        }
    }
    private var tracksApplied = false

    private suspend fun reload() { if (!closed) { delay(1500); load(item, 0) } }

    private fun report(path: String, force: Boolean = false) {
        val c = client ?: return
        val now = System.currentTimeMillis()
        val first = !reportedStart && playing
        if (!first && !force && (now - lastReport < 10_000 || !reportedStart)) return
        lastReport = now
        if (first) reportedStart = true
        val body = buildJsonObject {
            put("ItemId", item.id); mediaSourceId?.let { put("MediaSourceId", it) }; playSessionId?.let { put("PlaySessionId", it) }
            liveStreamId?.let { put("LiveStreamId", it) }
            put("PositionTicks", positionMs * 10_000); put("IsPaused", !playing); put("CanSeek", !isLive)
            put("PlayMethod", if (method.startsWith("Server")) "Transcode" else "DirectPlay")
            put("IsMuted", muted); put("VolumeLevel", volume)
        }
        AppState.scope.launch { c.reportPlayback(if (first) "Sessions/Playing" else path, body) }
    }

    // MARK: Skipping

    val activeSkip: MediaSegment? get() {
        val t = positionMs / 1000.0
        return segments.firstOrNull { it.type in setOf("Intro", "Recap", "Preview", "Commercial") && t >= it.start && t < it.end - 1 }
    }
    val skipLabel get() = when (activeSkip?.type) { "Recap" -> "Skip Recap"; "Preview" -> "Skip Preview"; "Commercial" -> "Skip Ad"; else -> "Skip Intro" }
    fun skipSegment() { activeSkip?.let { skipped += it.start; seekTo((it.end * 1000).toLong()) } }
    private fun autoSkip() {
        val s = activeSkip ?: return
        if (Prefs.autoSkipIntro && playing && s.start !in skipped && !SyncPlay.controls(this)) skipSegment()
    }

    private fun upNext() {
        val next = nextEpisode ?: return
        if (upNextDismissed || lengthMs <= 0 || !playing) return
        val creditsAt = segments.firstOrNull { it.type == "Outro" }?.start?.times(1000)?.toLong() ?: (lengthMs - 30_000)
        if (positionMs < creditsAt) { upNextIn = null; return }
        if (Prefs.autoSkipCredits) { playNext(); return }
        val left = 10 - ((positionMs - creditsAt) / 1000).toInt()
        if (left <= 0) playNext() else upNextIn = left
    }
    fun dismissUpNext() { upNextDismissed = true; upNextIn = null }
    fun playNext() {
        val next = nextEpisode ?: return
        upNextIn = null; upNextDismissed = true
        report("Sessions/Playing/Stopped", true)
        scope.launch { load(next, next.resumeTicks.takeIf { (next.progress ?: 0.0) < 0.9 } ?: 0) }
    }
    private fun onFinished() {
        report("Sessions/Playing/Stopped", true)
        if (isLive) { scope.launch { reload() }; return }
        if (nextEpisode != null) playNext() else close()
    }

    // MARK: Controls

    fun togglePlay() {
        if (SyncPlay.controls(this)) { scope.launch { SyncPlay.request(if (playing) SyncPlay.Req.Pause else SyncPlay.Req.Unpause) }; return }
        mp?.set("pause", if (playing) "yes" else "no"); playing = !playing
    }
    private fun seekMpv(ms: Long) { mp?.command("seek", "%.3f".format(java.util.Locale.US, ms / 1000.0), "absolute") }
    fun seekTo(ms: Long) {
        if (isLive) return
        val t = ms.coerceIn(0, (lengthMs - 1000).coerceAtLeast(0))
        if (SyncPlay.controls(this)) { scope.launch { SyncPlay.request(SyncPlay.Req.Seek(t * 10_000)) }; return }
        positionMs = t; seekMpv(t)
    }

    // Watch Together hooks (the group's server tells every player what to do).
    fun syncPlay() { mp?.set("pause", "no") }
    fun syncPause() { mp?.set("pause", "yes") }
    fun syncSeek(ticks: Long) { positionMs = ticks / 10_000; seekMpv(ticks / 10_000) }
    fun disableAutoNext() = dismissUpNext()
    suspend fun waitUntilReady() { repeat(225) { if (!loading || closed) return; delay(200) } }
    suspend fun switchItem(next: BaseItem, startTicks: Long) { if (!closed) { report("Sessions/Playing/Stopped", true); load(next, startTicks) } }
    fun seekBy(sec: Int) = seekTo(positionMs + sec * 1000L)
    fun changeVolume(v: Int) { volume = v.coerceIn(0, 200); mp?.set("volume", volume.toString()) }
    fun toggleMute() { muted = !muted; mp?.set("mute", if (muted) "yes" else "no") }
    fun selectAudio(id: Int) { mp?.set("aid", id.toString()); audioTrack = id }
    fun selectSubtitle(id: Int) { mp?.set("sid", if (id < 0) "no" else id.toString()); subtitleTrack = id }

    fun close() {
        if (closed) return
        closed = true
        if (active === this) active = null
        SyncPlay.unbind(this)
        report("Sessions/Playing/Stopped", true)
        ticker?.cancel()
        val p = mp; mp = null
        val c = client; val ps = playSessionId; val live = liveStreamId
        if (!hwnd.isCompleted) hwnd.cancel()
        p?.destroy()
        AppState.scope.launch { ps?.let { c?.stopEncoding(it) }; live?.let { c?.closeLiveStream(it) } }
        scope.cancel()
        onClose()
    }
}
