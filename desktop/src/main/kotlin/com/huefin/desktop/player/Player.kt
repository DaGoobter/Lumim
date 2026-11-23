package com.huefin.desktop.player

import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.ui.Nav

data class PlaybackRequest(val item: BaseItem, val startTicks: Long = 0, val mediaSourceId: String? = null, val localPath: String? = null)

/** Opens the player (shared screens call this the same way as on Android). */
object Player {
    fun play(context: Any?, item: BaseItem, startTicks: Long = 0, mediaSourceId: String? = null) = Nav.play(item, startTicks)
    fun open(context: Any?, request: PlaybackRequest) = Nav.play(request.item, request.startTicks)
}

typealias PlayerModel = PlayerController
