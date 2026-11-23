package com.huefin.desktop.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.huefin.desktop.HuefinApp
import com.huefin.desktop.core.AppState
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.JellyfinJson
import com.huefin.desktop.core.SessionSocket
import com.huefin.desktop.core.arr
import com.huefin.desktop.core.int
import com.huefin.desktop.core.long
import com.huefin.desktop.core.obj
import com.huefin.desktop.core.parseJellyfinDate
import com.huefin.desktop.core.str
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

/** Watch Together, using Jellyfin's SyncPlay: everyone in a group plays, pauses and seeks together. */
object SyncPlay {
    data class Group(val id: String, val name: String, val participants: List<String>)
    sealed interface Req { data object Pause : Req; data object Unpause : Req; data class Seek(val ticks: Long) : Req }

    var groupId by mutableStateOf<String?>(null); private set
    var groupName by mutableStateOf<String?>(null); private set
    var participants by mutableStateOf<List<String>>(emptyList()); private set
    var status by mutableStateOf<String?>(null); private set

    private var model: PlayerModel? = null
    private var client: JellyfinClient? = null
    private var offsetMs = 0L                     // server time ≈ local + offset
    private var playlistItemId: String? = null
    private var currentItemId: String? = null
    private var commandJob: Job? = null
    private var clockJob: Job? = null
    private val scope get() = AppState.scope

    fun bind(m: PlayerModel) { model = m; m.disableAutoNext() }
    fun unbind(m: PlayerModel) { if (model === m) model = null }
    fun controls(m: PlayerModel) = groupId != null && model === m

    suspend fun listGroups(c: JellyfinClient): List<Group> = runCatching {
        (JellyfinJson.parseToJsonElement(c.send("SyncPlay/List", method = "GET")) as? kotlinx.serialization.json.JsonArray ?: emptyList()).mapNotNull {
            Group(it.str("GroupId") ?: return@mapNotNull null, it.str("GroupName") ?: "Group",
                it.arr("Participants").mapNotNull { p -> (p as? JsonPrimitive)?.content })
        }
    }.getOrDefault(emptyList())

    private suspend fun connect(c: JellyfinClient) {
        client = c
        SessionSocket.connect(c)
        syncClock(c)
        clockJob?.cancel()
        clockJob = scope.launch { while (true) { delay(60_000); if (groupId != null) client?.let { syncClock(it) } } }
    }

    suspend fun create(c: JellyfinClient, m: PlayerModel, name: String) {
        connect(c); bind(m)
        c.send("SyncPlay/New", body = buildJsonObject { put("GroupName", name) })
        repeat(25) { if (groupId == null) delay(200) }
        currentItemId = m.item.id
        c.send("SyncPlay/SetNewQueue", body = buildJsonObject {
            put("PlayingQueue", buildJsonArray { add(JsonPrimitive(m.item.id)) }); put("PlayingItemPosition", 0); put("StartPositionTicks", m.positionTicks)
        })
    }

    suspend fun join(c: JellyfinClient, g: Group, m: PlayerModel?) {
        connect(c); m?.let { bind(it) }
        c.send("SyncPlay/Join", body = buildJsonObject { put("GroupId", g.id) })
    }

    suspend fun leave() { runCatching { client?.send("SyncPlay/Leave") }; reset() }

    suspend fun request(r: Req) {
        val c = client ?: return
        runCatching {
            when (r) {
                Req.Pause -> c.send("SyncPlay/Pause")
                Req.Unpause -> c.send("SyncPlay/Unpause")
                is Req.Seek -> c.send("SyncPlay/Seek", body = buildJsonObject { put("PositionTicks", r.ticks) })
            }
        }
    }

    private fun reset() { groupId = null; groupName = null; participants = emptyList(); status = null; playlistItemId = null; commandJob?.cancel(); clockJob?.cancel() }
    fun connectionLost() { if (groupId != null) status = "Connection lost. Reconnecting…" }

    private suspend fun syncClock(c: JellyfinClient) {
        var best: Pair<Long, Long>? = null
        repeat(3) {
            val t0 = System.currentTimeMillis()
            val o = runCatching { JellyfinJson.parseToJsonElement(c.send("GetUtcTime", method = "GET")) }.getOrNull() ?: return@repeat
            val t3 = System.currentTimeMillis()
            val r1 = o.str("RequestReceptionTime")?.let(::parseJellyfinDate)?.toEpochMilli() ?: return@repeat
            val r2 = o.str("ResponseTransmissionTime")?.let(::parseJellyfinDate)?.toEpochMilli() ?: return@repeat
            val rtt = (t3 - t0) - (r2 - r1)
            val off = ((r1 - t0) + (r2 - t3)) / 2
            if (best == null || rtt < best!!.first) best = rtt to off
        }
        best?.let { (rtt, off) -> offsetMs = off; runCatching { c.send("SyncPlay/Ping", body = buildJsonObject { put("Ping", rtt) }) } }
    }
    private val serverNow get() = System.currentTimeMillis() + offsetMs

    suspend fun handleGroupUpdate(u: JsonElement) {
        val type = u.str("Type") ?: return
        val data = (u as? kotlinx.serialization.json.JsonObject)?.get("Data")
        when (type) {
            "GroupJoined" -> { groupId = data.str("GroupId") ?: u.str("GroupId"); groupName = data.str("GroupName")
                participants = data.arr("Participants").mapNotNull { (it as? JsonPrimitive)?.content }; status = null }
            "UserJoined" -> { val n = (data as? JsonPrimitive)?.content; if (n != null && n !in participants) participants = participants + n; status = "${n ?: "Someone"} joined" }
            "UserLeft" -> { val n = (data as? JsonPrimitive)?.content; participants = participants - (n ?: ""); status = "${n ?: "Someone"} left" }
            "GroupLeft", "NotInGroup", "GroupDoesNotExist" -> reset()
            "LibraryAccessDenied" -> status = "Someone in the group can't access this video."
            "StateUpdate" -> { val st = data.str("State"); status = if (st == "Waiting") "Waiting for everyone…" else if (status == "Waiting for everyone…") null else status }
            "PlayQueue" -> handlePlayQueue(data)
        }
    }

    private suspend fun handlePlayQueue(q: JsonElement?) {
        val c = client ?: return
        val list = q.arr("Playlist"); if (list.isEmpty()) return
        val idx = (q.int("PlayingItemIndex") ?: 0).coerceIn(0, list.size - 1)
        val itemId = list[idx].str("ItemId") ?: return
        playlistItemId = list[idx].str("PlaylistItemId")
        val start = q.long("StartPositionTicks") ?: 0
        val m = model
        fun norm(s: String) = s.replace("-", "").lowercase()
        if (m != null && norm(m.item.id) == norm(itemId)) { m.syncPause(); m.syncSeek(start) }
        else if (m != null) {
            val item = runCatching { c.item(itemId) }.getOrNull() ?: return
            m.switchItem(item, start); m.disableAutoNext(); m.waitUntilReady(); m.syncPause()
        } else {
            val item = runCatching { c.item(itemId) }.getOrNull() ?: return
            currentItemId = itemId
            Player.open(HuefinApp.instance, PlaybackRequest(item, start))
            return
        }
        currentItemId = itemId
        sendReady()
    }

    /** A player opened for the group reports ready once it shows the video. */
    suspend fun playerOpened(m: PlayerModel) {
        if (groupId == null || currentItemId?.replace("-", "")?.lowercase() != m.item.id.replace("-", "").lowercase()) return
        bind(m); m.waitUntilReady(); m.syncPause(); sendReady()
    }

    private suspend fun sendReady() {
        val c = client ?: return; val m = model ?: return; val pid = playlistItemId ?: return
        runCatching { c.send("SyncPlay/Ready", body = buildJsonObject {
            put("When", Instant.ofEpochMilli(serverNow).toString()); put("PositionTicks", m.positionTicks); put("IsPlaying", false); put("PlaylistItemId", pid)
        }) }
    }

    fun handleCommand(cmd: JsonElement) {
        val m = model ?: return
        val command = cmd.str("Command") ?: return
        val ticks = cmd.long("PositionTicks")
        val whenMs = cmd.str("When")?.let(::parseJellyfinDate)?.toEpochMilli() ?: serverNow
        commandJob?.cancel()
        commandJob = scope.launch {
            when (command) {
                "Unpause" -> {
                    val delayMs = whenMs - serverNow
                    if (ticks != null) m.syncSeek(ticks + (if (delayMs < 0) -delayMs * 10_000 else 0))
                    val wait = whenMs - serverNow
                    if (wait > 0) delay(wait)
                    m.syncPlay()
                }
                "Pause" -> { m.syncPause(); ticks?.let { m.syncSeek(it) } }
                "Seek" -> { m.syncPause(); ticks?.let { m.syncSeek(it) }; m.waitUntilReady(); sendReady() }
                "Stop" -> m.syncPause()
            }
        }
    }
}
