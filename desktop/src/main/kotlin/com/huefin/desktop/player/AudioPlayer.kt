package com.huefin.desktop.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.SessionSocket
import com.huefin.desktop.downloads.DownloadManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import uk.co.caprica.vlcj.player.base.MediaPlayer
import uk.co.caprica.vlcj.player.base.MediaPlayerEventAdapter

/** Music, audiobooks and the DJ on Windows, played by VLC in the background while you browse. */
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
    private var mp: MediaPlayer? = null
    private var ticker: Job? = null
    private var djJob: Job? = null
    private var refilling = false
    private var lastReport = 0L
    private var reportedId: String? = null
    private var order: List<Int> = emptyList()   // play order when shuffled

    private fun player(): MediaPlayer? = mp ?: Vlc.factory()?.mediaPlayers()?.newMediaPlayer()?.also { p ->
        mp = p
        p.events().addMediaPlayerEventListener(object : MediaPlayerEventAdapter() {
            override fun playing(mediaPlayer: MediaPlayer) { AppState.scope.launch { isPlaying = true } }
            override fun paused(mediaPlayer: MediaPlayer) { AppState.scope.launch { isPlaying = false; report("Sessions/Playing/Progress", true) } }
            override fun lengthChanged(mediaPlayer: MediaPlayer, newLength: Long) { AppState.scope.launch { duration = newLength } }
            override fun finished(mediaPlayer: MediaPlayer) { AppState.scope.launch { advance(auto = true) } }
            override fun error(mediaPlayer: MediaPlayer) { AppState.scope.launch { advance(auto = true) } }
        })
    }

    fun play(context: Any?, items: List<BaseItem>, start: Int = 0, shuffled: Boolean = false) {
        station = null; shuffle = shuffled
        load(items.map { QueueEntry(it) }, start)
    }

    fun playStation(context: Any?, s: Station) {
        station = s; played.clear()
        AppState.scope.launch {
            val c = AppState.client ?: return@launch
            val first = runCatching { s.refill(c, emptySet()) }.getOrDefault(emptyList())
            if (first.isEmpty()) { SessionSocket.notice = SessionSocket.Notice(header = s.name, text = "Couldn't build this station. Is there music in your library?"); return@launch }
            first.firstNotNullOfOrNull { it.intro }?.let { launch { DJVoice.prefetch(it) } }
            shuffle = false
            load(first, 0)
        }
    }

    private fun load(entries: List<QueueEntry>, start: Int) {
        com.huefin.desktop.ui.Nav.player?.let { if (it.isPlaying) it.togglePlay() }
        queue = entries
        order = if (shuffle) (entries.indices - start).shuffled().let { listOf(start) + it } else entries.indices.toList()
        playAt(start)
        startTicker()
    }

    private fun playAt(i: Int) {
        val e = queue.getOrNull(i) ?: return
        val p = player() ?: return
        val old = queue.getOrNull(index)
        if (old != null && reportedId == old.id) report("Sessions/Playing/Stopped", true, old)
        index = i; position = 0; duration = (e.item.runTimeTicks ?: 0) / 10_000; reportedId = null
        played += e.id
        val local = DownloadManager.localFile(e.id)?.absolutePath
        p.media().play(local ?: AppState.client?.audioURL(e.id) ?: return)
        p.controls().setRate(speed)
        onEntryStarted(e)
        maybeRefill()
    }

    private fun advance(auto: Boolean) {
        if (queue.isEmpty()) return
        val pos = order.indexOf(index)
        val nextPos = pos + 1
        when {
            nextPos < order.size -> playAt(order[nextPos])
            repeat && station == null -> playAt(order.first())
            auto -> { isPlaying = false; report("Sessions/Playing/Stopped", true) }
        }
    }

    private fun onEntryStarted(e: QueueEntry) {
        djJob?.cancel(); DJVoice.stop()
        val p = mp ?: return
        val line = e.intro
        if (line == null) { djLine = null; p.audio().setVolume(100); return }
        djJob = AppState.scope.launch {
            djLine = DJVoice.display(line)
            p.audio().setVolume(18)
            DJVoice.say(line)
            for (i in 1..10) { if (!isActive) break; p.audio().setVolume(18 + (82 * i) / 10); delay(60) }
            p.audio().setVolume(100)
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
                val start = queue.size
                queue = queue + more
                order = order + (start until queue.size)
            } finally { refilling = false }
        }
    }

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = AppState.scope.launch {
            while (isActive) {
                mp?.let { position = it.status().time().coerceAtLeast(0); it.status().length().takeIf { l -> l > 0 }?.let { l -> duration = l } }
                report("Sessions/Playing/Progress")
                delay(500)
            }
        }
    }

    private fun report(path: String, force: Boolean = false, entry: QueueEntry? = queue.getOrNull(index)) {
        val e = entry ?: return
        val c = AppState.client ?: return
        val now = System.currentTimeMillis()
        val first = reportedId != e.id
        if (!force && !first && now - lastReport < 10_000) return
        if (first && !isPlaying) return
        lastReport = now
        val realPath = if (first && path != "Sessions/Playing/Stopped") { reportedId = e.id; "Sessions/Playing" } else path
        val ticks = (if (entry === queue.getOrNull(index)) position else duration) * 10_000
        val paused = !isPlaying
        AppState.scope.launch {
            c.reportPlayback(realPath, buildJsonObject {
                put("ItemId", e.id); put("PositionTicks", ticks); put("IsPaused", paused); put("PlayMethod", "DirectPlay"); put("CanSeek", true)
            })
        }
    }

    fun addNext(items: List<BaseItem>) {
        if (queue.isEmpty()) return play(null, items)
        val at = index + 1
        queue = queue.take(at) + items.map { QueueEntry(it) } + queue.drop(at)
        val pos = order.indexOf(index)
        val shifted = order.map { if (it >= at) it + items.size else it }
        order = shifted.take(pos + 1) + (at until at + items.size) + shifted.drop(pos + 1)
    }
    fun addToQueue(items: List<BaseItem>) {
        if (queue.isEmpty()) return play(null, items)
        val start = queue.size
        queue = queue + items.map { QueueEntry(it) }
        order = order + (start until queue.size)
    }

    fun pause() { mp?.controls()?.setPause(true) }
    fun resume() { mp?.controls()?.play() }
    fun togglePlay() { mp?.controls()?.pause() }
    fun pauseForVideo() { DJVoice.stop(); pause() }
    fun next() = advance(auto = false)
    fun previous() {
        if (position > 3000) { seek(0); return }
        val pos = order.indexOf(index)
        if (pos > 0) playAt(order[pos - 1]) else seek(0)
    }
    fun seek(ms: Long) { mp?.controls()?.setTime(ms.coerceAtLeast(0)); position = ms }
    fun jump(to: Int) { if (to in queue.indices) playAt(to) }
    fun toggleShuffle() {
        shuffle = !shuffle
        order = if (shuffle) listOf(index) + (queue.indices - index).shuffled() else queue.indices.toList()
    }
    fun toggleRepeat() { repeat = !repeat }
    fun changeSpeed(s: Float) { speed = s; mp?.controls()?.setRate(s) }

    fun stop() {
        report("Sessions/Playing/Stopped", true)
        djJob?.cancel(); DJVoice.stop(); ticker?.cancel()
        val p = mp
        if (p != null) Thread { runCatching { p.controls().stop() } }.start()
        queue = emptyList(); station = null; djLine = null; isPlaying = false; reportedId = null; showNowPlaying = false
    }
}
