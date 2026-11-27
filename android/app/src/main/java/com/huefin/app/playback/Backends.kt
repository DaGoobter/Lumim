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
    /** Subtitle timing in seconds (positive = later). Only the Huefin Engine can shift subtitles. */
    val supportsSubtitleDelay: Boolean get() = false
    fun setSubtitleDelay(seconds: Double) {}
    /** Audio sync (seconds, positive = sound later) and night mode — Huefin Engine only. */
    fun setAudioDelay(seconds: Double) {}
    fun setNightMode(on: Boolean) {}
    val supportsBoost: Boolean get() = false
    fun release()
    var onEnded: () -> Unit
    var onError: (String) -> Unit
    var onReady: () -> Unit
    /** What the server says about the video (VideoRangeType like "HDR10" or "DOVI", and the codec), before prepare. */
    fun setVideoHint(rangeType: String?, codec: String?) {}
    /** Text subtitles the app must draw itself (when the engine can't draw on the picture). */
    val overlaySubtitle: String? get() = null
    /** One line about how the picture is being drawn, for the info panel. */
    val detail: String get() = ""
}

/**
 * Android's renderers plus the FFmpeg audio decoder (used after Android's own decoders, for what they can't play).
 * Added by hand rather than through Media3's automatic loading, which treats any problem with it as fatal: here a
 * problem just leaves it out (and is reported), and Android's player carries on without it.
 */
@OptIn(UnstableApi::class)
private class SafeRenderersFactory(context: Context) : androidx.media3.exoplayer.DefaultRenderersFactory(context) {
    override fun buildAudioRenderers(
        context: Context, extensionRendererMode: Int, mediaCodecSelector: androidx.media3.exoplayer.mediacodec.MediaCodecSelector,
        enableDecoderFallback: Boolean, audioSink: androidx.media3.exoplayer.audio.AudioSink, eventHandler: android.os.Handler,
        eventListener: androidx.media3.exoplayer.audio.AudioRendererEventListener, out: ArrayList<androidx.media3.exoplayer.Renderer>,
    ) {
        super.buildAudioRenderers(context, EXTENSION_RENDERER_MODE_OFF, mediaCodecSelector, enableDecoderFallback, audioSink, eventHandler, eventListener, out)
        runCatching { out.add(androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer(eventHandler, eventListener, audioSink)) }
            .onFailure { com.huefin.app.core.CrashReport.note("FFmpeg audio couldn't load; TrueHD/DTS will use the Huefin Engine.", it) }
    }
    /** Whether FFmpeg's decoders actually loaded on this phone. */
    companion object { val ffmpegReady: Boolean get() = runCatching { androidx.media3.decoder.ffmpeg.FfmpegLibrary.isAvailable() }.getOrDefault(false) }
}

/** Android's player (Media3 ExoPlayer). */
@OptIn(UnstableApi::class)
class ExoBackend(context: Context) : Backend {
    override val name = "Android player"
    override var onEnded: () -> Unit = {}
    override var onError: (String) -> Unit = {}
    override var onReady: () -> Unit = {}
    // FFmpeg (Jellyfin's build of Media3's decoder) adds TrueHD, DTS and other audio Android can't decode, so Dolby
    // Vision and HDR files with that audio still play in Android's own player, in true DV/HDR.
    val exo: ExoPlayer = ExoPlayer.Builder(context, SafeRenderersFactory(context).setEnableDecoderFallback(true))
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

/** Whether FFmpeg's audio decoders loaded on this phone (decides what the server is told Android's player can play). */
fun ffmpegAudioReady(): Boolean = SafeRenderersFactory.ffmpegReady
