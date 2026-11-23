package com.huefin.app.playback

import android.content.Context
import android.net.Uri
import android.view.View
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.huefin.app.core.JellyfinClient
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.util.VLCVideoLayout

data class SubtitleSource(val url: String, val mime: String, val language: String?, val label: String)
data class Track(val id: String, val label: String, val selected: Boolean, val language: String? = null)

/** One video engine. The player screen and PlayerModel don't care which. */
interface Backend {
    val name: String
    fun createView(context: Context): View
    fun prepare(url: String, startMs: Long, subtitles: List<SubtitleSource>, hls: Boolean)
    fun play(); fun pause(); fun seekTo(ms: Long)
    val positionMs: Long; val durationMs: Long; val isPlaying: Boolean; val isBuffering: Boolean
    fun setSpeed(speed: Float)
    fun audioTracks(): List<Track>; fun subtitleTracks(): List<Track>
    fun selectAudio(id: String); fun selectSubtitle(id: String?)
    fun setFill(fill: Boolean)
    fun setVolumeBoost(percent: Int) {}
    val supportsBoost: Boolean get() = false
    fun release()
    var onEnded: () -> Unit
    var onError: (String) -> Unit
    var onReady: () -> Unit
}

/** Android's player (Media3 ExoPlayer). */
@OptIn(UnstableApi::class)
class ExoBackend(context: Context) : Backend {
    override val name = "Android player"
    override var onEnded: () -> Unit = {}
    override var onError: (String) -> Unit = {}
    override var onReady: () -> Unit = {}
    val exo: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(OkHttpDataSource.Factory(JellyfinClient.http)))
        .setSeekBackIncrementMs(10_000).setSeekForwardIncrementMs(10_000)
        .build().apply {
            addListener(object : androidx.media3.common.Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    if (state == androidx.media3.common.Player.STATE_ENDED) onEnded()
                    if (state == androidx.media3.common.Player.STATE_READY) onReady()
                }
                override fun onPlayerError(error: PlaybackException) { onError(error.errorCodeName) }
            })
        }
    private var playerView: PlayerView? = null

    override fun createView(context: Context): View = PlayerView(context).apply {
        useController = false
        player = exo
        setShutterBackgroundColor(android.graphics.Color.BLACK)
        playerView = this
    }

    override fun prepare(url: String, startMs: Long, subtitles: List<SubtitleSource>, hls: Boolean) {
        val subs = subtitles.map {
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(it.url)).setMimeType(it.mime).setLanguage(it.language).setLabel(it.label).build()
        }
        val item = MediaItem.Builder().setUri(url).setSubtitleConfigurations(subs)
            .apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }.build()
        exo.setMediaItem(item, startMs)
        exo.prepare()
        exo.playWhenReady = true
    }

    override fun play() = exo.play()
    override fun pause() = exo.pause()
    override fun seekTo(ms: Long) = exo.seekTo(ms)
    override val positionMs get() = exo.currentPosition
    override val durationMs get() = exo.duration.takeIf { it != C.TIME_UNSET } ?: 0
    override val isPlaying get() = exo.isPlaying
    override val isBuffering get() = exo.playbackState == androidx.media3.common.Player.STATE_BUFFERING
    override fun setSpeed(speed: Float) = exo.setPlaybackSpeed(speed)

    private fun tracksOf(type: Int): List<Track> = exo.currentTracks.groups.filter { it.type == type }.mapIndexed { gi, g ->
        val f = g.getTrackFormat(0)
        val label = listOfNotNull(f.label, f.language?.let { java.util.Locale(it).displayLanguage }, f.codecs?.substringBefore('.')?.uppercase(),
            if (f.channelCount > 0 && type == C.TRACK_TYPE_AUDIO) "${f.channelCount}ch" else null).distinct().joinToString(" · ").ifEmpty { "Track ${gi + 1}" }
        Track("$type:$gi", label, g.isSelected, f.language)
    }
    override fun audioTracks() = tracksOf(C.TRACK_TYPE_AUDIO)
    override fun subtitleTracks() = tracksOf(C.TRACK_TYPE_TEXT)

    private fun group(id: String) = id.split(":").let { (t, i) -> exo.currentTracks.groups.filter { it.type == t.toInt() }.getOrNull(i.toInt()) }
    override fun selectAudio(id: String) {
        val g = group(id) ?: return
        exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon().setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, 0)).build()
    }
    override fun selectSubtitle(id: String?) {
        val b = exo.trackSelectionParameters.buildUpon()
        if (id == null) b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        else group(id)?.let { b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(it.mediaTrackGroup, 0)) }
        exo.trackSelectionParameters = b.build()
    }
    override fun setFill(fill: Boolean) {
        playerView?.resizeMode = if (fill) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
    override fun release() { playerView?.player = null; exo.release() }
}

/** The Huefin Engine (libVLC): plays MKV, AVI, DTS, TrueHD, PGS subtitles and more straight from the original file. */
class VlcBackend(context: Context) : Backend {
    override val name = "Huefin Engine"
    override var onEnded: () -> Unit = {}
    override var onError: (String) -> Unit = {}
    override var onReady: () -> Unit = {}
    private val lib = LibVLC(context.applicationContext, arrayListOf("--network-caching=3000", "--no-stats", "--audio-time-stretch"))
    private val mp = org.videolan.libvlc.MediaPlayer(lib)
    private var layout: VLCVideoLayout? = null
    private var buffering = false
    private var readySent = false
    override val supportsBoost = true

    init {
        mp.setEventListener { e ->
            when (e.type) {
                org.videolan.libvlc.MediaPlayer.Event.EndReached -> onEnded()
                org.videolan.libvlc.MediaPlayer.Event.EncounteredError -> onError("The Huefin Engine couldn't open this file.")
                org.videolan.libvlc.MediaPlayer.Event.Buffering -> buffering = e.buffering < 100f
                org.videolan.libvlc.MediaPlayer.Event.Playing -> { buffering = false; if (!readySent) { readySent = true; onReady() } }
            }
        }
    }

    override fun createView(context: Context): View = VLCVideoLayout(context).also {
        layout = it
        mp.attachViews(it, null, true, false)
    }

    override fun prepare(url: String, startMs: Long, subtitles: List<SubtitleSource>, hls: Boolean) {
        readySent = false
        val media = Media(lib, Uri.parse(url))
        media.setHWDecoderEnabled(true, false)
        if (startMs > 0) media.addOption(":start-time=${startMs / 1000.0}")
        mp.media = media
        media.release()
        subtitles.forEach { mp.addSlave(org.videolan.libvlc.interfaces.IMedia.Slave.Type.Subtitle, Uri.parse(it.url), false) }
        mp.play()
    }

    override fun play() { mp.play() }
    override fun pause() { mp.pause() }
    override fun seekTo(ms: Long) { mp.time = ms }
    override val positionMs get() = mp.time.coerceAtLeast(0)
    override val durationMs get() = mp.length.coerceAtLeast(0)
    override val isPlaying get() = mp.isPlaying
    override val isBuffering get() = buffering
    override fun setSpeed(speed: Float) { mp.rate = speed }
    override fun audioTracks() = (mp.audioTracks ?: emptyArray()).filter { it.id >= 0 }.map { Track(it.id.toString(), it.name ?: "Track", it.id == mp.audioTrack) }
    override fun subtitleTracks() = (mp.spuTracks ?: emptyArray()).filter { it.id >= 0 }.map { Track(it.id.toString(), it.name ?: "Subtitles", it.id == mp.spuTrack) }
    override fun selectAudio(id: String) { mp.audioTrack = id.toInt() }
    override fun selectSubtitle(id: String?) { mp.spuTrack = id?.toInt() ?: -1 }
    override fun setFill(fill: Boolean) { mp.videoScale = if (fill) org.videolan.libvlc.MediaPlayer.ScaleType.SURFACE_FILL else org.videolan.libvlc.MediaPlayer.ScaleType.SURFACE_BEST_FIT }
    override fun setVolumeBoost(percent: Int) { mp.volume = percent.coerceIn(0, 200) }
    override fun release() {
        runCatching { mp.stop(); mp.detachViews(); mp.release(); lib.release() }
    }
}
