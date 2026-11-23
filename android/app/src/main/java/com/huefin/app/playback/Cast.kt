package com.huefin.app.playback

import android.content.Context
import android.net.Uri
import androidx.appcompat.view.ContextThemeWrapper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.mediarouter.app.MediaRouteChooserDialog
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.common.images.WebImage
import com.huefin.app.core.AppState
import com.huefin.app.core.JellyfinClient

class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder().setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID).build()
    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/** Chromecast / Google TV: hand what's playing to the TV (an H.264/AAC stream every Cast device can play). */
object Cast {
    var deviceName by mutableStateOf<String?>(null); private set
    private var pendingModel: PlayerModel? = null
    private var listening = false

    private fun context(ctx: Context): CastContext? = runCatching { CastContext.getSharedInstance(ctx.applicationContext) }.getOrNull()

    fun showPicker(ctx: Context, m: PlayerModel) {
        val cc = context(ctx) ?: return
        pendingModel = m
        if (!listening) {
            listening = true
            cc.sessionManager.addSessionManagerListener(object : SessionManagerListener<CastSession> {
                override fun onSessionStarted(session: CastSession, sessionId: String) {
                    deviceName = session.castDevice?.friendlyName ?: "TV"
                    pendingModel?.let { model -> load(session, model); model.syncPause() }
                }
                override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) { deviceName = session.castDevice?.friendlyName }
                override fun onSessionEnded(session: CastSession, error: Int) { deviceName = null }
                override fun onSessionStarting(session: CastSession) {}
                override fun onSessionStartFailed(session: CastSession, error: Int) {}
                override fun onSessionEnding(session: CastSession) {}
                override fun onSessionResuming(session: CastSession, sessionId: String) {}
                override fun onSessionResumeFailed(session: CastSession, error: Int) {}
                override fun onSessionSuspended(session: CastSession, reason: Int) {}
            }, CastSession::class.java)
        }
        val current = cc.sessionManager.currentCastSession
        if (current != null && current.isConnected) { load(current, m); m.syncPause(); return }
        MediaRouteChooserDialog(ContextThemeWrapper(ctx, androidx.appcompat.R.style.Theme_AppCompat_NoActionBar)).apply {
            routeSelector = cc.mergedSelector ?: return
            show()
        }
    }

    private fun load(session: CastSession, m: PlayerModel) {
        val api: JellyfinClient = AppState.client ?: return
        val item = m.item
        val url = api.url("Videos/${item.id}/master.m3u8", mapOf(
            "MediaSourceId" to (item.mediaSources?.firstOrNull()?.id ?: item.id), "DeviceId" to JellyfinClient.deviceId + "-cast",
            "VideoCodec" to "h264", "AudioCodec" to "aac", "MaxStreamingBitrate" to "20000000", "TranscodingMaxAudioChannels" to "2",
            "SegmentContainer" to "ts", "api_key" to api.accessToken))
        val meta = MediaMetadata(if (item.type == "Episode") MediaMetadata.MEDIA_TYPE_TV_SHOW else MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, item.displayTitle)
            item.episodeLabel?.let { putString(MediaMetadata.KEY_SUBTITLE, it) }
            addImage(WebImage(Uri.parse(api.backdropURL(item, 1280))))
        }
        val info = MediaInfo.Builder(url).setStreamType(MediaInfo.STREAM_TYPE_BUFFERED).setContentType("application/x-mpegURL").setMetadata(meta).build()
        session.remoteMediaClient?.load(MediaLoadRequestData.Builder().setMediaInfo(info).setAutoplay(true)
            .setCurrentTime((m.position * 1000).toLong()).build())
    }

    fun stop(ctx: Context) { context(ctx)?.sessionManager?.endCurrentSession(true); deviceName = null }
}
