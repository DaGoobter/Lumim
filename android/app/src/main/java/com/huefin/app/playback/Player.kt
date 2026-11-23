package com.huefin.app.playback

import android.content.Context
import android.content.Intent
import com.huefin.app.core.BaseItem
import com.huefin.app.downloads.DownloadManager
import com.huefin.app.downloads.DownloadState

data class PlaybackRequest(
    val item: BaseItem,
    val startTicks: Long = 0,
    val mediaSourceId: String? = null,
    /** A finished download to play from the phone instead of the server. */
    val localPath: String? = null,
)

/** Opens the full-screen player. */
object Player {
    @Volatile var pending: PlaybackRequest? = null

    fun play(context: Context, item: BaseItem, startTicks: Long = 0, mediaSourceId: String? = null) {
        val rec = DownloadManager.records[item.id]
        val local = rec?.takeIf { it.state == DownloadState.Completed }?.localPath
        val start = rec?.positionTicks?.takeIf { local != null && it > startTicks } ?: startTicks
        open(context, PlaybackRequest(item, start, mediaSourceId, local))
    }

    fun open(context: Context, request: PlaybackRequest) {
        AudioPlayer.pauseForVideo()
        pending = request
        context.startActivity(Intent(context, PlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
