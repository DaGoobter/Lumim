package com.huefin.app.core

import android.app.NotificationManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.huefin.app.HuefinApp
import com.huefin.app.R
import com.huefin.app.playback.AudioPlayer
import com.huefin.app.playback.PlayerModel
import com.huefin.app.playback.SyncPlay
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.UUID

/** Huefin's live line to the server: lets a parent or admin pause, stop or message this device, and carries Watch Together. */
object SessionSocket {
    data class Notice(val id: String = UUID.randomUUID().toString(), val header: String, val text: String)
    var notice by mutableStateOf<Notice?>(null)

    private var socket: WebSocket? = null
    private var client: JellyfinClient? = null
    private var keepAlive: Job? = null
    val isConnected get() = socket != null

    suspend fun connect(c: JellyfinClient) {
        if (socket != null && client === c) return
        disconnect()
        client = c
        runCatching { c.send("Sessions/Capabilities/Full", body = buildJsonObject {
            put("PlayableMediaTypes", buildJsonArray { add(JsonPrimitive("Video")); add(JsonPrimitive("Audio")) })
            put("SupportsMediaControl", true)
            put("SupportedCommands", buildJsonArray { listOf("DisplayMessage", "Play", "Pause", "Seek", "Stop", "PlayPause", "SetVolume").forEach { add(JsonPrimitive(it)) } })
        }) }
        val wsUrl = c.url("socket", mapOf("ApiKey" to c.accessToken, "deviceId" to JellyfinClient.deviceId)).replaceFirst("http", "ws")
        socket = JellyfinClient.http.newWebSocket(Request.Builder().url(wsUrl).build(), object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) { AppState.scope.launch { handle(text) } }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { dropped(webSocket) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { dropped(webSocket) }
        })
        keepAlive = AppState.scope.launch { while (true) { delay(30_000); socket?.send("""{"MessageType":"KeepAlive"}""") } }
    }

    private fun dropped(ws: WebSocket) {
        if (socket !== ws) return
        socket = null
        AppState.scope.launch {
            SyncPlay.connectionLost()
            delay(5000)
            client?.let { if (AppState.client === it) connect(it) }
        }
    }

    fun disconnect() { keepAlive?.cancel(); socket?.close(1000, null); socket = null }

    private suspend fun handle(text: String) {
        val o = runCatching { JellyfinJson.parseToJsonElement(text) }.getOrNull() ?: return
        val data = (o as? JsonObject)?.get("Data")
        when (o.str("MessageType")) {
            "SyncPlayGroupUpdate" -> data?.let { SyncPlay.handleGroupUpdate(it) }
            "SyncPlayCommand" -> data?.let { SyncPlay.handleCommand(it) }
            "Playstate" -> playstate(data)
            "GeneralCommand" -> general(data)
        }
    }

    private fun playstate(d: JsonElement?) {
        val cmd = d.str("Command")
        val ticks = d.long("SeekPositionTicks")
        val p = PlayerModel.active
        if (p != null) when (cmd) {
            "Pause" -> p.syncPause(); "Unpause" -> p.syncPlay()
            "PlayPause" -> if (p.isPlaying) p.syncPause() else p.syncPlay()
            "Stop" -> { p.syncPause(); p.onClose() }
            "Seek" -> ticks?.let { p.syncSeek(it) }
        } else when (cmd) {
            "Pause" -> AudioPlayer.pause(); "Unpause", "PlayPause" -> AudioPlayer.togglePlay(); "Stop" -> AudioPlayer.stop()
            "NextTrack" -> AudioPlayer.next(); "PreviousTrack" -> AudioPlayer.previous()
            "Seek" -> ticks?.let { AudioPlayer.seek(it / 10_000) }
        }
    }

    private fun general(d: JsonElement?) {
        if (d.str("Name") != "DisplayMessage") return
        val args = d.obj("Arguments")
        val text = args.str("Text")?.takeIf { it.isNotBlank() } ?: return
        val header = args.str("Header") ?: "Message"
        notice = Notice(header = header, text = text)
        // If Huefin is in the background, show it as a notification too.
        if (!ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            val ctx = HuefinApp.instance
            ctx.getSystemService(NotificationManager::class.java).notify(text.hashCode(),
                NotificationCompat.Builder(ctx, "messages").setSmallIcon(R.drawable.ic_stat_huefin).setContentTitle(header).setContentText(text)
                    .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true).build())
        }
    }
}
