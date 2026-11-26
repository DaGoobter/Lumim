package com.huefin.app.playback

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.core.ChapterMarker
import com.huefin.app.core.JellyfinClient
import com.huefin.app.core.MediaSegment
import com.huefin.app.core.Prefs
import com.huefin.app.core.TrickplayInfo
import com.huefin.app.downloads.DownloadManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Request

/** Everything about one viewing: what's playing, the server session, skipping, up next, sleep timer. */
class PlayerModel(var request: PlaybackRequest, val backend: Backend) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val client: JellyfinClient? = AppState.client

    var item by mutableStateOf(request.item); private set
    var isPlaying by mutableStateOf(false); private set
    var loading by mutableStateOf(true); private set
    private var lastTickPos = -1L
    var buffering by mutableStateOf(false); private set
    var position by mutableStateOf(0.0); private set     // seconds
    var duration by mutableStateOf(0.0); private set
    var error by mutableStateOf<String?>(null); private set
    var speed by mutableFloatStateOf(1f); private set
    var sleepAt by mutableStateOf<Long?>(null); private set
    var sleepAtEnd by mutableStateOf(false); private set
    var segments by mutableStateOf<List<MediaSegment>>(emptyList()); private set
    var chapters by mutableStateOf<List<ChapterMarker>>(emptyList()); private set
    var nextEpisode by mutableStateOf<BaseItem?>(null); private set
    var upNextCountdown by mutableStateOf<Int?>(null); private set
    var autoSkipIn by mutableStateOf<Int?>(null); private set
    var playMethod by mutableStateOf("—"); private set
    var liveStatus by mutableStateOf<String?>(null); private set
    var fill by mutableStateOf(false)
    var volumeBoost by mutableStateOf(100)
    /** Subtitle text the screen draws itself (Huefin Engine in HDR passthrough). */
    var overlaySubtitle by mutableStateOf<String?>(null); private set

    val isLive get() = item.isLiveChannel
    val isOffline get() = request.localPath != null

    private var mediaSourceId: String? = null
    private var playSessionId: String? = null
    private var liveStreamId: String? = null
    private var reportedMethod = "DirectPlay"
    private var trickplay: TrickplayInfo? = null
    private var stopped = false
    private var upNextDismissed = false
    private var upNextShownAt: Long? = null
    private var autoSkipSeg: Double? = null
    private var autoSkipSince = 0L
    private val autoSkipDeclined = mutableSetOf<Double>()
    private var sleepJob: Job? = null
    private var tickJob: Job? = null
    private var lastReport = 0L
    private var reconnects = mutableListOf<Long>()
    var onClose: () -> Unit = {}

    init {
        backend.onEnded = { com.huefin.app.core.CrashReport.step("Video ended"); scope.launch { ended() } }
        backend.onError = { msg -> com.huefin.app.core.CrashReport.step("Playback error: $msg"); scope.launch { if (isLive) reconnectLive() else { error = msg; loading = false } } }
        backend.onReady = { com.huefin.app.core.CrashReport.step("Video playing"); scope.launch { loading = false } }
    }

    fun start() {
        active = this
        scope.launch { load(request.startTicks); loadExtras() }
        tickJob = scope.launch { while (isActive) { tick(); delay(500) } }
    }

    // MARK: Loading

    private suspend fun load(startTicks: Long) {
        loading = true; error = null
        val startMs = startTicks / 10_000
        request.localPath?.let { path ->
            playMethod = "Offline (downloaded)"
            item.mediaSources?.firstOrNull()?.videoStream?.let { v -> backend.setVideoHint(v.videoRangeType ?: v.videoRange, v.codec) }
            backend.prepare(java.io.File(path).toURI().toString(), startMs, emptyList(), path.endsWith(".m3u8"))
            return
        }
        val c = client ?: run { error = "Not connected to your server."; return }
        val max = AppState.maxBitrate
        val info = try {
            c.playbackInfo(item.id, max, EngineDecider.profile(max), startTicks, mediaSourceId = request.mediaSourceId,
                enableDirectPlay = true, subtitleStreamIndex = if (backend is MpvBackend) null else -1)
        } catch (e: Exception) { error = e.message ?: "Couldn't start playback."; loading = false; return }
        val src = info.mediaSources.firstOrNull { it.id == request.mediaSourceId } ?: info.mediaSources.firstOrNull()
            ?: run { error = "Nothing playable in this item."; loading = false; return }
        mediaSourceId = src.id; playSessionId = info.playSessionId; liveStreamId = src.liveStreamId
        src.videoStream?.let { v -> backend.setVideoHint(v.videoRangeType ?: v.videoRange, v.codec) }
        val subs = mutableListOf<SubtitleSource>()
        val url: String
        var hls = false
        when {
            isLive -> {
                url = src.transcodingUrl?.let { c.absoluteURL(it, live = true) }
                    ?: c.liveHLSURL(item.id, src.id, src.liveStreamId, info.playSessionId, max, com.huefin.app.core.DeviceProfile.capabilities(com.huefin.app.HuefinApp.instance).hevc)
                hls = true; reportedMethod = "Transcode"; playMethod = "Live stream (HLS)"
            }
            backend is MpvBackend || src.supportsDirectPlay == true -> {
                url = c.directPlayURL(item.id, src.id, src.container)
                reportedMethod = "DirectPlay"
                playMethod = if (backend is MpvBackend) "Huefin Engine (original file)" else "Direct Play (original file)"
                src.subtitleStreams.filter { it.isExternal == true }.forEach { s -> subtitleFor(c, src.id, s)?.let(subs::add) }
            }
            src.transcodingUrl != null -> {
                url = c.absoluteURL(src.transcodingUrl)
                hls = true
                reportedMethod = if (src.supportsDirectStream == true) "DirectStream" else "Transcode"
                playMethod = if (src.supportsDirectStream == true) "Direct Stream (remux, full quality)" else "Transcode (server converts)"
                src.subtitleStreams.forEach { s -> subtitleFor(c, src.id, s)?.let(subs::add) }
            }
            else -> { error = "The server can't stream this item."; loading = false; return }
        }
        com.huefin.app.core.CrashReport.step("Starting: $playMethod · ${src.container} · ${src.videoStream?.codec} ${src.videoStream?.videoRangeType} · audio ${src.audioStreams.joinToString { it.codec ?: "?" }}")
        backend.prepare(url, if (isLive) 0 else startMs, subs, hls)
        report("Sessions/Playing")
    }

    private fun subtitleFor(c: JellyfinClient, sourceId: String, s: com.huefin.app.core.MediaStream): SubtitleSource? {
        val idx = s.index ?: return null
        val codec = (s.codec ?: "").lowercase()
        if (codec in setOf("pgssub", "dvdsub", "dvbsub", "pgs")) return null   // picture subtitles can't be sent as text
        val (ext, mime) = when (codec) { "ass", "ssa" -> "ass" to "text/x-ssa"; "srt", "subrip" -> "srt" to "application/x-subrip"; else -> "vtt" to "text/vtt" }
        val label = listOfNotNull(s.displayTitle ?: s.title, if (s.isForced == true) "Forced" else null).joinToString(" · ").ifEmpty { s.language ?: "Subtitles" }
        return SubtitleSource(c.url("Videos/${item.id}/$sourceId/Subtitles/$idx/0/Stream.$ext", mapOf("api_key" to c.accessToken)), mime, s.language, label)
    }

    private suspend fun loadExtras() {
        val c = client ?: return
        if (isLive) return
        segments = c.mediaSegments(item.id)
        val extras = c.playbackExtras(item.id)
        chapters = extras.chapters ?: emptyList()
        trickplay = extras.trickplay?.values?.firstOrNull()?.values?.maxByOrNull { it.width ?: 0 }
        nextEpisode = when (item.type) {
            "Episode" -> c.episodeAfter(item)
            "Movie" -> c.additionalParts(item.id).firstOrNull()
            else -> null
        }
    }

    // MARK: Clock

    private suspend fun tick() {
        if (stopped) return
        position = backend.positionMs / 1000.0
        val d = backend.durationMs / 1000.0
        duration = if (d > 0) d else (item.runTimeTicks ?: 0) / 10_000_000.0
        isPlaying = backend.isPlaying
        overlaySubtitle = backend.overlaySubtitle
        if (backend is MpvBackend && playMethod.startsWith("Huefin Engine")) playMethod = "Huefin Engine · ${backend.detail}"
        // Some streams keep reporting "buffering" while they play; if the clock is moving, it's playing.
        val pos = backend.positionMs
        val moving = backend.isPlaying && pos > lastTickPos + 50
        lastTickPos = pos
        if (moving && loading) loading = false
        buffering = backend.isBuffering && !moving
        if (isLive) liveStatus = if (buffering && !loading) "Buffering…" else null
        val now = System.currentTimeMillis()
        if (now - lastReport > 10_000 && !loading) { lastReport = now; report("Sessions/Playing/Progress") }
        updateAutoSkip(); updateUpNext()
        applyTrackPrefs()
    }

    private var tracksApplied = false
    /** Picks audio and subtitles from Settings → Audio & Subtitles once the tracks are known. */
    private fun applyTrackPrefs() {
        if (tracksApplied || loading) return
        val audio = backend.audioTracks()
        if (audio.isEmpty()) return
        tracksApplied = true
        val (a, sub) = com.huefin.app.core.TrackPrefs.choose(audio, backend.subtitleTracks())
        a?.let { if (!audio.first { t -> t.id == it }.selected) backend.selectAudio(it) }
        backend.selectSubtitle(sub)
    }

    val activeSkip: MediaSegment?
        get() = segments.firstOrNull { it.type in setOf("Intro", "Recap", "Preview", "Commercial") && position >= it.start && position < it.end - 1 }
    val skipLabel get() = when (activeSkip?.type) { "Recap" -> "Skip Recap"; "Preview" -> "Skip Preview"; "Commercial" -> "Skip Ad"; else -> "Skip Intro" }
    private val creditsStart: Double?
        get() = segments.firstOrNull { it.type == "Outro" }?.start ?: if (duration > 120) duration - 30 else null

    fun skipSegment() { activeSkip?.let { autoSkipIn = null; seek(it.end) } }
    fun cancelAutoSkip() { activeSkip?.let { autoSkipDeclined += it.start }; autoSkipIn = null }

    private fun updateAutoSkip() {
        val seg = activeSkip
        if (seg == null || !isPlaying || SyncPlay.controls(this)) { if (seg == null) { autoSkipIn = null; autoSkipSeg = null }; return }
        val wanted = if (seg.type == "Recap") Prefs.autoSkipRecap else Prefs.autoSkipIntro
        if (!wanted || seg.start in autoSkipDeclined) { autoSkipIn = null; return }
        if (autoSkipSeg != seg.start) { autoSkipSeg = seg.start; autoSkipSince = System.currentTimeMillis() }
        val left = Prefs.autoSkipDelay - ((System.currentTimeMillis() - autoSkipSince) / 1000).toInt()
        if (left <= 0) { autoSkipDeclined += seg.start; skipSegment() } else autoSkipIn = left
    }

    private fun updateUpNext() {
        val start = creditsStart
        if (nextEpisode == null || upNextDismissed || sleepAtEnd || start == null || position < start || loading) {
            if (upNextCountdown != null && position < (start ?: Double.MAX_VALUE)) { upNextCountdown = null; upNextShownAt = null }
            return
        }
        if (Prefs.autoSkipCredits && isPlaying) { scope.launch { playNext() }; return }
        if (upNextShownAt == null) upNextShownAt = System.currentTimeMillis()
        if (!isPlaying) return
        val left = 10 - ((System.currentTimeMillis() - (upNextShownAt ?: 0)) / 1000).toInt()
        upNextCountdown = left.coerceAtLeast(0)
        if (left <= 0) scope.launch { playNext() }
    }

    fun dismissUpNext() { upNextDismissed = true; upNextCountdown = null }
    fun disableAutoNext() = dismissUpNext()

    suspend fun playNext() { nextEpisode?.let { switchItem(it, 0) } }

    /** Swap what's playing without closing the player (next episode, Watch Together). */
    suspend fun switchItem(next: BaseItem, startTicks: Long) {
        if (stopped) return
        report("Sessions/Playing/Stopped")
        playSessionId?.let { id -> client?.stopEncoding(id) }
        nextEpisode = null; upNextCountdown = null; upNextShownAt = null; upNextDismissed = false
        autoSkipDeclined.clear(); autoSkipIn = null; segments = emptyList(); chapters = emptyList(); trickplay = null
        val rec = DownloadManager.records[next.id]?.takeIf { it.state == com.huefin.app.downloads.DownloadState.Completed }
        request = PlaybackRequest(next, startTicks, null, rec?.localPath)
        item = next
        load(startTicks)
        loadExtras()
    }

    private suspend fun ended() {
        if (sleepAtEnd) { sleepAtEnd = false; backend.pause(); return }
        if (nextEpisode != null && !upNextDismissed && !SyncPlay.controls(this)) playNext()
        else if (!isLive) onClose()
    }

    // MARK: Controls

    fun togglePlay() {
        val wantsPlay = !backend.isPlaying
        if (SyncPlay.controls(this)) { scope.launch { SyncPlay.request(if (wantsPlay) SyncPlay.Req.Unpause else SyncPlay.Req.Pause) }; return }
        if (wantsPlay) backend.play() else backend.pause()
        isPlaying = wantsPlay
    }
    fun seek(seconds: Double) {
        position = seconds
        if (SyncPlay.controls(this)) { scope.launch { SyncPlay.request(SyncPlay.Req.Seek((seconds * 10_000_000).toLong())) }; return }
        backend.seekTo((seconds * 1000).toLong())
    }
    fun skip(by: Double) = seek((position + by).coerceIn(0.0, if (duration > 0) duration else Double.MAX_VALUE))

    // Applied by Watch Together and family remote control (bypass the group).
    fun syncPlay() { backend.play(); isPlaying = true }
    fun syncPause() { backend.pause(); isPlaying = false }
    fun syncSeek(ticks: Long) { position = ticks / 10_000_000.0; backend.seekTo(ticks / 10_000) }
    val positionTicks get() = backend.positionMs * 10_000
    suspend fun waitUntilReady() { repeat(225) { if (!loading || stopped) return; delay(200) } }

    fun changeSpeed(s: Float) { speed = s; backend.setSpeed(s) }
    fun setBoost(p: Int) { volumeBoost = p; backend.setVolumeBoost(p) }
    fun toggleFill() { fill = !fill; backend.setFill(fill) }

    fun setSleepTimer(minutes: Int?) {
        sleepJob?.cancel(); sleepAtEnd = false
        if (minutes == null || minutes <= 0) { sleepAt = null; return }
        sleepAt = System.currentTimeMillis() + minutes * 60_000L
        sleepJob = scope.launch { delay(minutes * 60_000L); backend.pause(); sleepAt = null }
    }
    fun setSleepAtEnd() { sleepJob?.cancel(); sleepAt = null; sleepAtEnd = true }

    fun chapterAt(seconds: Double) = chapters.lastOrNull { it.start <= seconds }

    private val tileCache = HashMap<Int, Bitmap>()
    /** Scrubbing thumbnail, cut out of the server's sprite sheet. */
    suspend fun thumbnail(seconds: Double): Bitmap? {
        val info = trickplay ?: return null
        val c = client ?: return null
        val sid = mediaSourceId ?: return null
        val w = info.width ?: return null; val interval = info.interval ?: return null
        val tw = info.tileWidth ?: return null; val th = info.tileHeight ?: return null
        if (interval <= 0 || tw <= 0 || th <= 0) return null
        val perTile = tw * th
        val frame = ((seconds * 1000).toInt() / interval).coerceIn(0, ((info.thumbnailCount ?: Int.MAX_VALUE) - 1).coerceAtLeast(0))
        val tileIndex = frame / perTile
        val sheet = tileCache[tileIndex] ?: withContext(Dispatchers.IO) {
            runCatching {
                JellyfinClient.http.newCall(Request.Builder().url(c.trickplayTileURL(item.id, w, tileIndex, sid)).header("Authorization", c.authHeader).build())
                    .execute().use { r -> r.body?.byteStream()?.let(BitmapFactory::decodeStream) }
            }.getOrNull()
        }?.also { tileCache[tileIndex] = it } ?: return null
        val cell = frame % perTile
        val cw = sheet.width / tw; val ch = (info.height ?: (sheet.height / th)).coerceAtMost(sheet.height / th)
        val x = (cell % tw) * cw; val y = (cell / tw) * (sheet.height / th)
        if (x + cw > sheet.width || y + ch > sheet.height) return null
        return Bitmap.createBitmap(sheet, x, y, cw, ch)
    }

    // MARK: Live TV resilience

    private suspend fun reconnectLive() {
        val now = System.currentTimeMillis()
        reconnects.removeAll { now - it > 120_000 }
        if (reconnects.size >= 4) { error = "The channel keeps dropping. Try again in a moment."; return }
        reconnects += now
        liveStatus = "Reconnecting…"
        liveStreamId?.let { client?.closeLiveStream(it) }
        delay(1500)
        load(0)
    }

    // MARK: Server reporting

    private suspend fun report(path: String) {
        val ticks = backend.positionMs * 10_000
        if (request.localPath != null) {
            if (!path.endsWith("Playing") && ticks > 0) DownloadManager.recordOfflineProgress(item.id, ticks)
            return
        }
        val c = client ?: return
        c.reportPlayback(path, buildJsonObject {
            put("ItemId", item.id); put("PositionTicks", ticks); put("IsPaused", !backend.isPlaying)
            put("PlayMethod", reportedMethod); put("CanSeek", !isLive)
            mediaSourceId?.let { put("MediaSourceId", it) }
            playSessionId?.let { put("PlaySessionId", it) }
            liveStreamId?.let { put("LiveStreamId", it) }
        })
    }

    suspend fun stop() {
        if (stopped) return
        report("Sessions/Playing/Stopped")
        stopped = true
        if (active === this) active = null
        sleepJob?.cancel(); tickJob?.cancel()
        SyncPlay.unbind(this)
        playSessionId?.let { client?.stopEncoding(it) }
        liveStreamId?.let { client?.closeLiveStream(it) }
        backend.release()
        if (item.type == "Episode") DownloadManager.runSmart(force = true)
        scope.cancel()
    }

    companion object {
        /** The player on screen right now (for family remote control and Watch Together). */
        @Volatile var active: PlayerModel? = null
    }
}
