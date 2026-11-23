package com.huefin.app.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player as M3Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.huefin.app.HuefinApp
import com.huefin.app.core.AppState
import com.huefin.app.core.BaseItem
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.downloads.DownloadState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/** Music, audiobooks and the DJ. Runs in the background with a notification, lock screen controls and Android Auto. */
object AudioPlayer {
    var queue by mutableStateOf<List<QueueEntry>>(emptyList()); private set
    var index by mutableStateOf(0); private set
    var isPlaying by mutableStateOf(false); private set
    var position by mutableLongStateOf(0L); private set
    var duration by mutableLongStateOf(0L); private set
    var station by mutableStateOf<Station?>(null); private set
    var djLine by mutableStateOf<String?>(null); private set
    var shuffle by mutableStateOf(false); private set
    var repeat by mutableStateOf(false); private set
    var showNowPlaying by mutableStateOf(false)
    var speed by mutableStateOf(1f); private set

    val current: BaseItem? get() = queue.getOrNull(index)?.item
    private val played = mutableSetOf<String>()
    private var exo: ExoPlayer? = null
    private var controller: MediaController? = null
    private var ticker: Job? = null
    private var djJob: Job? = null
    private var refilling = false
    private var lastReport = 0L
    private var reportedId: String? = null

    fun player(context: Context): ExoPlayer = exo ?: ExoPlayer.Builder(context.applicationContext)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .build().also { p ->
            exo = p
            p.addListener(object : M3Player.Listener {
                override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing; report(if (playing) "Sessions/Playing/Progress" else "Sessions/Playing/Progress", force = true) }
                override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                    val old = queue.getOrNull(index)
                    if (old != null && reportedId == old.id) report("Sessions/Playing/Stopped", force = true, entry = old)
                    index = p.currentMediaItemIndex
                    current?.let { played += it.id }
                    reportedId = null
                    onEntryStarted()
                    maybeRefill()
                }
                override fun onPlaybackStateChanged(state: Int) { duration = p.duration.coerceAtLeast(0) }
            })
        }

    private fun bindService(context: Context) {
        if (controller != null) return
        val token = SessionToken(context, ComponentName(context, AudioService::class.java))
        val f = MediaController.Builder(context, token).buildAsync()
        f.addListener({ controller = runCatching { f.get() }.getOrNull() }, { it.run() })
    }

    private fun mediaItem(e: QueueEntry): MediaItem {
        val c = AppState.client
        val rec = DownloadManager.records[e.id]?.takeIf { it.state == DownloadState.Completed }
        val uri = rec?.localPath?.let { Uri.fromFile(File(it)) } ?: Uri.parse(c?.audioURL(e.id) ?: "")
        val art = c?.albumArtURL(e.item)
        return MediaItem.Builder().setMediaId(e.id).setUri(uri).setMediaMetadata(MediaMetadata.Builder()
            .setTitle(e.item.name).setArtist(e.item.artistLine).setAlbumTitle(e.item.album)
            .setArtworkUri(art?.let(Uri::parse)).setIsPlayable(true).setIsBrowsable(false).build()).build()
    }

    fun play(context: Context, items: List<BaseItem>, start: Int = 0, shuffled: Boolean = false) {
        station = null
        shuffle = shuffled
        load(context, items.map { QueueEntry(it) }, start)
    }

    fun playStation(context: Context, s: Station) {
        station = s
        played.clear()
        AppState.scope.launch {
            val c = AppState.client ?: return@launch
            val first = runCatching { s.refill(c, emptySet()) }.getOrDefault(emptyList())
            if (first.isEmpty()) { com.huefin.app.core.SessionSocket.notice = com.huefin.app.core.SessionSocket.Notice(header = s.name, text = "Couldn't build this station. Is there music in your library?"); return@launch }
            first.firstNotNullOfOrNull { it.intro }?.let { launch { DJVoice.prefetch(it) } }
            load(context, first, 0)
        }
    }

    private fun load(context: Context, entries: List<QueueEntry>, start: Int) {
        val p = player(context)
        bindService(context)
        queue = entries
        index = start
        p.setMediaItems(entries.map(::mediaItem), start, 0)
        p.shuffleModeEnabled = shuffle && station == null
        p.prepare()
        p.play()
        onEntryStarted()
        startTicker()
    }

    /** Android Auto asked for a queue: remember it and hand back the items for the session to play. */
    fun adopt(context: Context, entries: List<QueueEntry>, s: Station?): List<MediaItem> {
        player(context); station = s; played.clear(); queue = entries; index = 0
        entries.firstNotNullOfOrNull { it.intro }?.let { AppState.scope.launch { DJVoice.prefetch(it) } }
        startTicker()
        return entries.map(::mediaItem)
    }

    fun addNext(items: List<BaseItem>) {
        val p = exo ?: return play(HuefinApp.instance, items)
        val at = (index + 1).coerceAtMost(queue.size)
        queue = queue.take(at) + items.map { QueueEntry(it) } + queue.drop(at)
        p.addMediaItems(at, items.map { mediaItem(QueueEntry(it)) })
    }

    private fun onEntryStarted() {
        val e = queue.getOrNull(index) ?: return
        djJob?.cancel(); DJVoice.stop()
        val line = e.intro
        if (line == null) { djLine = null; exo?.volume = 1f; return }
        djJob = AppState.scope.launch {
            val p = exo ?: return@launch
            djLine = DJVoice.display(line)
            p.volume = 0.18f
            DJVoice.say(line)
            // Fade the music back up.
            for (i in 1..10) { if (!isActive) break; p.volume = 0.18f + 0.082f * i; delay(60) }
            p.volume = 1f
            delay(2500); djLine = null
        }
    }

    private fun maybeRefill() {
        val s = station ?: return
        if (refilling || queue.size - index > 3) return
        refilling = true
        AppState.scope.launch {
            try {
                val c = AppState.client ?: return@launch
                val more = runCatching { s.refill(c, played + queue.map { it.id }) }.getOrDefault(emptyList())
                if (more.isEmpty()) return@launch
                more.firstNotNullOfOrNull { it.intro }?.let { launch { DJVoice.prefetch(it) } }
                queue = queue + more
                exo?.addMediaItems(more.map(::mediaItem))
            } finally { refilling = false }
        }
    }

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = AppState.scope.launch {
            while (isActive) {
                exo?.let { position = it.currentPosition.coerceAtLeast(0); duration = it.duration.coerceAtLeast(0) }
                report("Sessions/Playing/Progress")
                delay(500)
            }
        }
    }

    private fun report(path: String, force: Boolean = false, entry: QueueEntry? = queue.getOrNull(index)) {
        val e = entry ?: return
        val c = AppState.client ?: return
        val now = System.currentTimeMillis()
        val p = exo ?: return
        val first = reportedId != e.id
        if (!force && !first && now - lastReport < 10_000) return
        lastReport = now
        val realPath = if (first && path != "Sessions/Playing/Stopped") { reportedId = e.id; "Sessions/Playing" } else path
        val ticks = (if (entry === queue.getOrNull(index)) p.currentPosition else duration) * 10_000
        AppState.scope.launch {
            c.reportPlayback(realPath, buildJsonObject {
                put("ItemId", e.id); put("PositionTicks", ticks); put("IsPaused", !p.isPlaying)
                put("PlayMethod", "DirectPlay"); put("CanSeek", true)
            })
        }
    }

    fun pause() { exo?.pause() }
    fun resume() { exo?.play() }
    fun togglePlay() { exo?.let { if (it.isPlaying) it.pause() else it.play() } }
    fun pauseForVideo() { DJVoice.stop(); exo?.pause() }
    fun next() { exo?.let { if (it.hasNextMediaItem()) it.seekToNextMediaItem() } }
    fun previous() { exo?.let { if (it.currentPosition > 3000 || !it.hasPreviousMediaItem()) it.seekTo(0) else it.seekToPreviousMediaItem() } }
    fun seek(ms: Long) { exo?.seekTo(ms) }
    fun jump(to: Int) { exo?.seekTo(to, 0) }
    fun toggleShuffle() { shuffle = !shuffle; exo?.shuffleModeEnabled = shuffle && station == null }
    fun toggleRepeat() { repeat = !repeat; exo?.repeatMode = if (repeat) M3Player.REPEAT_MODE_ALL else M3Player.REPEAT_MODE_OFF }
    fun setSpeed(s: Float) { speed = s; exo?.setPlaybackSpeed(s) }
    fun addToQueue(items: List<BaseItem>) {
        if (exo == null || queue.isEmpty()) return play(HuefinApp.instance, items)
        queue = queue + items.map { QueueEntry(it) }; exo?.addMediaItems(items.map { mediaItem(QueueEntry(it)) })
    }

    fun stop() {
        report("Sessions/Playing/Stopped", force = true)
        djJob?.cancel(); DJVoice.stop(); ticker?.cancel()
        exo?.stop(); exo?.clearMediaItems()
        queue = emptyList(); station = null; djLine = null; isPlaying = false; reportedId = null
        controller?.release(); controller = null
    }
}
