package com.huefin.desktop.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.MediaSegment
import com.huefin.desktop.core.Prefs
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
import uk.co.caprica.vlcj.media.MediaSlavePriority
import uk.co.caprica.vlcj.media.MediaSlaveType
import uk.co.caprica.vlcj.player.base.MediaPlayer
import uk.co.caprica.vlcj.player.base.MediaPlayerEventAdapter
import uk.co.caprica.vlcj.player.embedded.EmbeddedMediaPlayer

data class TrackChoice(val id: Int, val label: String)
/** A track as the shared track-preference code sees it. */
data class Track(val id: String, val label: String, val selected: Boolean, val language: String? = null)

/** Plays one item (and the next episodes) with VLC, reports progress to the server, skips intros and credits. */
class PlayerController(start: BaseItem, private val startTicks: Long, val onClose: () -> Unit) {
    companion object { var active: PlayerController? = null }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val client: JellyfinClient? = AppState.client
    val surface = VideoSurface()
    private var mp: EmbeddedMediaPlayer? = null

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
        val f = Vlc.factory() ?: run { error = Vlc.loadError; loading = false; return }
        val p = f.mediaPlayers().newEmbeddedMediaPlayer()
        surface.attach(p, f)
        p.events().addMediaPlayerEventListener(object : MediaPlayerEventAdapter() {
            override fun playing(mediaPlayer: MediaPlayer) { scope.launch { playing = true; loading = false; refreshTracks() } }
            override fun paused(mediaPlayer: MediaPlayer) { scope.launch { playing = false; report("Sessions/Playing/Progress", true) } }
            override fun stopped(mediaPlayer: MediaPlayer) { scope.launch { playing = false } }
            override fun buffering(mediaPlayer: MediaPlayer, newCache: Float) { scope.launch { loading = newCache < 100f && !playing } }
            override fun lengthChanged(mediaPlayer: MediaPlayer, newLength: Long) { scope.launch { lengthMs = newLength } }
            override fun elementaryStreamAdded(mediaPlayer: MediaPlayer, type: uk.co.caprica.vlcj.media.TrackType, id: Int) { scope.launch { refreshTracks() } }
            override fun finished(mediaPlayer: MediaPlayer) { scope.launch { onFinished() } }
            override fun error(mediaPlayer: MediaPlayer) { scope.launch { if (isLive) reload() else { error = "This couldn't be played."; loading = false } } }
        })
        mp = p
        scope.launch { load(item, startTicks); SyncPlay.playerOpened(this@PlayerController) }
        ticker = scope.launch {
            while (isActive) {
                mp?.let { positionMs = it.status().time().coerceAtLeast(0); if (lengthMs <= 0) lengthMs = it.status().length() }
                report("Sessions/Playing/Progress")
                autoSkip(); upNext()
                delay(250)
            }
        }
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

    private suspend fun load(target: BaseItem, ticks: Long) {
        val p = mp ?: return
        loading = true; error = null; reportedStart = false; upNextDismissed = false; upNextIn = null; skipped.clear(); tracksApplied = false
        com.huefin.desktop.downloads.DownloadManager.localFile(target.id)?.let { f ->
            method = "Downloaded (offline)"; item = target; mediaSourceId = null; playSessionId = null; liveStreamId = null
            val opts = if (ticks > 0) arrayOf(":start-time=${ticks / 10_000_000.0}") else emptyArray()
            p.media().play(f.absolutePath, *opts)
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
        val opts = mutableListOf<String>()
        if (ticks > 0 && !target.isLiveChannel) opts += ":start-time=${ticks / 10_000_000.0}"
        opts += ":http-user-agent=Huefin for Windows"
        p.media().play(url, *opts.toTypedArray())
        // Subtitle files kept next to the video on the server.
        src.mediaStreams.orEmpty().filter { it.type == "Subtitle" && it.isExternal == true && it.index != null }.forEach { s ->
            val ext = when ((s.codec ?: "").lowercase()) { "ass", "ssa" -> "ass"; "vtt", "webvtt" -> "vtt"; else -> "srt" }
            p.media().slaves().add(MediaSlaveType.SUBTITLE, MediaSlavePriority.HIGHEST,
                c.url("Videos/${target.id}/${src.id}/Subtitles/${s.index}/0/Stream.$ext", mapOf("api_key" to c.accessToken)))
        }
        item = target
        positionMs = 0; lengthMs = (target.runTimeTicks ?: 0) / 10_000
        segments = if (target.isLiveChannel) emptyList() else c.mediaSegments(target.id)
        nextEpisode = if (target.type == "Episode") c.episodeAfter(target) else null
    }

    private fun refreshTracks() {
        val p = mp ?: return
        audioTracks = p.audio().trackDescriptions().filter { it.id() >= 0 }.map { TrackChoice(it.id(), it.description()) }
        subtitleTracks = p.subpictures().trackDescriptions().filter { it.id() >= 0 }.map { TrackChoice(it.id(), it.description()) }
        audioTrack = p.audio().track(); subtitleTrack = p.subpictures().track()
        if (!tracksApplied && audioTracks.isNotEmpty() && playing) {
            tracksApplied = true
            val (a, sub) = com.huefin.desktop.core.TrackPrefs.choose(
                audioTracks.map { Track(it.id.toString(), it.label, it.id == audioTrack) },
                subtitleTracks.map { Track(it.id.toString(), it.label, it.id == subtitleTrack) })
            a?.toIntOrNull()?.let { selectAudio(it) }
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
        mp?.controls()?.pause()
    }
    fun seekTo(ms: Long) {
        if (isLive) return
        val t = ms.coerceIn(0, (lengthMs - 1000).coerceAtLeast(0))
        if (SyncPlay.controls(this)) { scope.launch { SyncPlay.request(SyncPlay.Req.Seek(t * 10_000)) }; return }
        mp?.controls()?.setTime(t)
    }

    // Watch Together hooks (the group's server tells every player what to do).
    fun syncPlay() { mp?.controls()?.play() }
    fun syncPause() { mp?.controls()?.setPause(true) }
    fun syncSeek(ticks: Long) { positionMs = ticks / 10_000; mp?.controls()?.setTime(ticks / 10_000) }
    fun disableAutoNext() = dismissUpNext()
    suspend fun waitUntilReady() { repeat(225) { if (!loading || closed) return; delay(200) } }
    suspend fun switchItem(next: BaseItem, startTicks: Long) { if (!closed) { report("Sessions/Playing/Stopped", true); load(next, startTicks) } }
    fun seekBy(sec: Int) = seekTo(positionMs + sec * 1000L)
    fun changeVolume(v: Int) { volume = v.coerceIn(0, 200); mp?.audio()?.setVolume(volume) }
    fun toggleMute() { muted = !muted; mp?.audio()?.isMute = muted }
    fun selectAudio(id: Int) { mp?.audio()?.setTrack(id); audioTrack = id }
    fun selectSubtitle(id: Int) { mp?.subpictures()?.setTrack(id); subtitleTrack = id }

    fun close() {
        if (closed) return
        closed = true
        if (active === this) active = null
        SyncPlay.unbind(this)
        report("Sessions/Playing/Stopped", true)
        ticker?.cancel()
        val p = mp; mp = null
        val c = client; val ps = playSessionId; val live = liveStreamId
        Thread { runCatching { p?.controls()?.stop(); p?.release() } }.start()
        AppState.scope.launch { ps?.let { c?.stopEncoding(it) }; live?.let { c?.closeLiveStream(it) } }
        scope.cancel()
        onClose()
    }
}
