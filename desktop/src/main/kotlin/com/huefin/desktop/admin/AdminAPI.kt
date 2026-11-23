package com.huefin.desktop.admin

import com.huefin.desktop.core.BaseItem
import com.huefin.desktop.core.HttpError
import com.huefin.desktop.core.JellyfinClient
import com.huefin.desktop.core.JellyfinJson
import com.huefin.desktop.core.parseJellyfinDate
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.LocalDate

@Serializable data class AdminPlayState(val positionTicks: Long? = null, val isPaused: Boolean? = null, val playMethod: String? = null)
@Serializable data class AdminTranscodingInfo(
    val audioCodec: String? = null, val videoCodec: String? = null, val container: String? = null,
    val isVideoDirect: Boolean? = null, val isAudioDirect: Boolean? = null, val bitrate: Int? = null, val framerate: Double? = null,
    val completionPercentage: Double? = null, val width: Int? = null, val height: Int? = null, val audioChannels: Int? = null,
    val hardwareAccelerationType: String? = null, val transcodeReasons: List<String>? = null,
)

@Serializable
data class AdminSession(
    val id: String, val userId: String? = null, val userName: String? = null, val client: String? = null,
    val deviceName: String? = null, val deviceId: String? = null, val applicationVersion: String? = null,
    val remoteEndPoint: String? = null, val lastActivityDate: String? = null, val nowPlayingItem: BaseItem? = null,
    val playState: AdminPlayState? = null, val transcodingInfo: AdminTranscodingInfo? = null, val supportsRemoteControl: Boolean? = null,
) {
    val isPaused get() = playState?.isPaused ?: false
    val progress: Double? get() {
        val pos = playState?.positionTicks ?: return null; val total = nowPlayingItem?.runTimeTicks ?: return null
        return if (total > 0) (pos.toDouble() / total).coerceIn(0.0, 1.0) else null
    }
    val method: String get() {
        val t = transcodingInfo ?: return if (playState?.playMethod == "Transcode") "Transcode" else "Direct Play"
        return when {
            t.isVideoDirect == true && t.isAudioDirect == true -> "Remux"
            t.isVideoDirect == true -> "Audio converted"
            nowPlayingItem?.isAudio == true && t.isAudioDirect == true -> "Remux"
            else -> "Transcode"
        }
    }
    val isLocal: Boolean get() {
        val ip = remoteEndPoint ?: return false
        return ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("127.") || ip.startsWith("::1") || Regex("""^172\.(1[6-9]|2\d|3[01])\.""").containsMatchIn(ip)
    }
}

@Serializable data class AdminSystemInfo(val serverName: String? = null, val version: String? = null, val operatingSystemDisplayName: String? = null,
    val hasPendingRestart: Boolean? = null, val hasUpdateAvailable: Boolean? = null, val canSelfRestart: Boolean? = null)

@Serializable data class FolderStorage(val path: String? = null, val freeSpace: Long? = null, val usedSpace: Long? = null, val deviceId: String? = null) {
    val total get() = (freeSpace ?: 0).coerceAtLeast(0) + (usedSpace ?: 0).coerceAtLeast(0)
    val fraction get() = if (total > 0) (usedSpace ?: 0).coerceAtLeast(0).toDouble() / total else 0.0
    val driveLabel: String get() { val p = path ?: return "Drive"; return if (p.length >= 2 && p[1] == ':') p.take(2) + "\\" else p }
}
@Serializable data class LibraryStorage(val id: String? = null, val name: String? = null, val folders: List<FolderStorage>? = null)
@Serializable data class SystemStorage(val programDataFolder: FolderStorage? = null, val cacheFolder: FolderStorage? = null,
    val transcodingTempFolder: FolderStorage? = null, val libraries: List<LibraryStorage>? = null) {
    /** One entry per physical drive, labelled with what lives on it. */
    val drives: List<Pair<FolderStorage, List<String>>> get() {
        val map = linkedMapOf<String, Pair<FolderStorage, MutableList<String>>>()
        fun add(f: FolderStorage?, use: String) {
            if (f == null || f.total <= 0) return
            val e = map.getOrPut(f.deviceId ?: f.driveLabel) { f to mutableListOf() }
            if (use !in e.second) e.second += use
        }
        libraries.orEmpty().forEach { lib -> lib.folders.orEmpty().forEach { add(it, lib.name ?: "Library") } }
        add(programDataFolder, "Jellyfin data"); add(transcodingTempFolder, "Transcodes"); add(cacheFolder, "Cache")
        return map.values.map { it.first to it.second.toList() }
    }
}
@Serializable data class ItemCounts(val movieCount: Int? = null, val seriesCount: Int? = null, val episodeCount: Int? = null,
    val albumCount: Int? = null, val songCount: Int? = null, val bookCount: Int? = null)
@Serializable data class VirtualFolder(val name: String? = null, val itemId: String? = null, val collectionType: String? = null,
    val locations: List<String>? = null, val refreshProgress: Double? = null, val refreshStatus: String? = null)
@Serializable data class AdminUserPolicy(
    val isAdministrator: Boolean? = null, val isDisabled: Boolean? = null, val enableRemoteAccess: Boolean? = null,
    val enableContentDownloading: Boolean? = null, val enableVideoPlaybackTranscoding: Boolean? = null,
    val enableAudioPlaybackTranscoding: Boolean? = null, val enablePlaybackRemuxing: Boolean? = null,
    val enableLiveTvAccess: Boolean? = null, val remoteClientBitrateLimit: Int? = null, val enableRemoteControlOfOtherUsers: Boolean? = null,
)
@Serializable data class AdminUser(val id: String, val name: String? = null, val primaryImageTag: String? = null, val hasPassword: Boolean? = null,
    val lastActivityDate: String? = null, val policy: AdminUserPolicy? = null) {
    val lastActive: Instant? get() = lastActivityDate?.let(::parseJellyfinDate)
}
@Serializable data class TaskResult(val endTimeUtc: String? = null, val status: String? = null, val errorMessage: String? = null)
@Serializable data class ScheduledTask(val id: String, val name: String? = null, val state: String? = null, val currentProgressPercentage: Double? = null,
    val category: String? = null, val description: String? = null, val lastExecutionResult: TaskResult? = null) {
    val isRunning get() = state == "Running" || state == "Cancelling"
}
@Serializable data class ActivityEntry(val id: Long, val name: String? = null, val shortOverview: String? = null, val overview: String? = null,
    val type: String? = null, val date: String? = null, val severity: String? = null)
@Serializable data class ActivityPage(val items: List<ActivityEntry> = emptyList(), val totalRecordCount: Int? = null)
@Serializable data class LogFile(val name: String, val size: Long? = null, val dateModified: String? = null)
@Serializable data class DeviceEntry(val id: String, val name: String? = null, val customName: String? = null, val appName: String? = null,
    val appVersion: String? = null, val lastUserName: String? = null, val dateLastActivity: String? = null)
@Serializable data class DevicePage(val items: List<DeviceEntry> = emptyList())
@Serializable data class PluginInfo(val id: String, val name: String? = null, val version: String? = null, val description: String? = null, val status: String? = null)
@Serializable private data class Me(val policy: AdminUserPolicy? = null)

data class WatchStats(
    val days: List<Pair<LocalDate, Double>>, val methods: List<Pair<String, Int>>,
    val users: List<Triple<String, Double, Int>>, val titles: List<Triple<String, Double, Int>>,
) { val totalHours get() = days.sumOf { it.second } }

suspend fun JellyfinClient.isAdministrator(): Boolean = runCatching { get<Me>("Users/Me").policy?.isAdministrator == true }.getOrDefault(false)
/** Admins, and people the admin marked as a parent, can control other people's playback. */
suspend fun JellyfinClient.canControlOthers(): Boolean = runCatching {
    val p = get<Me>("Users/Me").policy; p?.isAdministrator == true || p?.enableRemoteControlOfOtherUsers == true }.getOrDefault(false)
suspend fun JellyfinClient.controllableSessions(): List<AdminSession> = get("Sessions", mapOf("controllableByUserId" to userId, "activeWithinSeconds" to "960"))
suspend fun JellyfinClient.adminSessions(): List<AdminSession> = get("Sessions", mapOf("activeWithinSeconds" to "960"))
suspend fun JellyfinClient.sessionCommand(id: String, command: String) { send("Sessions/$id/Playing/$command") }
suspend fun JellyfinClient.sendMessage(id: String, header: String, text: String) {
    send("Sessions/$id/Message", body = buildJsonObject { put("Header", header); put("Text", text); put("TimeoutMs", 8000) })
}
suspend fun JellyfinClient.adminSystemInfo(): AdminSystemInfo = get("System/Info")
suspend fun JellyfinClient.adminStorage(): SystemStorage = get("System/Info/Storage")
suspend fun JellyfinClient.adminCounts(): ItemCounts = get("Items/Counts")
suspend fun JellyfinClient.adminLibraries(): List<VirtualFolder> = get("Library/VirtualFolders")
suspend fun JellyfinClient.adminScanAll() { send("Library/Refresh") }
suspend fun JellyfinClient.adminRefresh(itemId: String, replaceAll: Boolean) {
    val mode = if (replaceAll) "FullRefresh" else "Default"
    send("Items/$itemId/Refresh", mapOf("Recursive" to "true", "MetadataRefreshMode" to mode, "ImageRefreshMode" to mode,
        "ReplaceAllMetadata" to replaceAll.toString(), "ReplaceAllImages" to replaceAll.toString()))
}
suspend fun JellyfinClient.adminUsers(): List<AdminUser> = get("Users")
suspend fun JellyfinClient.adminUser(id: String): AdminUser = get("Users/$id")
/** Change a few policy switches without touching the rest of the user's policy. */
suspend fun JellyfinClient.adminUpdatePolicy(userId: String, changes: Map<String, JsonPrimitive>) {
    val user = JellyfinJson.parseToJsonElement(send("Users/$userId", method = "GET")).jsonObject
    val policy = user["Policy"]?.jsonObject ?: throw HttpError(500)
    send("Users/$userId/Policy", body = JsonObject(policy + changes))
}
suspend fun JellyfinClient.adminTasks(): List<ScheduledTask> = get("ScheduledTasks", mapOf("isHidden" to "false"))
suspend fun JellyfinClient.adminStartTask(id: String) { send("ScheduledTasks/Running/$id") }
suspend fun JellyfinClient.adminStopTask(id: String) { send("ScheduledTasks/Running/$id", method = "DELETE") }
suspend fun JellyfinClient.adminActivity(start: Int, limit: Int = 50): ActivityPage =
    get("System/ActivityLog/Entries", mapOf("startIndex" to start.toString(), "limit" to limit.toString()))
suspend fun JellyfinClient.adminLogs(): List<LogFile> = get("System/Logs")
suspend fun JellyfinClient.adminLog(name: String): String = send("System/Logs/Log", mapOf("name" to name), "GET")
suspend fun JellyfinClient.adminDevices(): List<DeviceEntry> = get<DevicePage>("Devices").items
suspend fun JellyfinClient.adminDeleteDevice(id: String) { send("Devices", mapOf("id" to id), "DELETE") }
suspend fun JellyfinClient.adminPlugins(): List<PluginInfo> = get("Plugins")
suspend fun JellyfinClient.adminRestart() { send("System/Restart") }
suspend fun JellyfinClient.adminShutdown() { send("System/Shutdown") }

private suspend fun JellyfinClient.reportQuery(sql: String): List<List<String>> {
    val r = JellyfinJson.parseToJsonElement(send("user_usage_stats/submit_custom_query",
        body = buildJsonObject { put("CustomQueryString", sql); put("ReplaceUserId", true) })).jsonObject
    return (r["results"] as? JsonArray)?.map { row -> row.jsonArray.map { (it as? JsonPrimitive)?.content ?: it.toString() } } ?: emptyList()
}

/** Hours watched, how things play, top viewers and titles. Null when the Playback Reporting plugin isn't installed. */
suspend fun JellyfinClient.adminWatchStats(): WatchStats? = runCatching {
    val since14 = "datetime('now', '-13 days', 'start of day')"; val since30 = "datetime('now', '-30 days')"
    val byDay = reportQuery("SELECT date(DateCreated) AS d, SUM(PlayDuration) FROM PlaybackActivity WHERE DateCreated >= $since14 GROUP BY d ORDER BY d")
        .filter { it.size >= 2 }.associate { it[0] to (it[1].toDoubleOrNull() ?: 0.0) / 3600 }
    val today = LocalDate.now()
    val days = (13 downTo 0).map { today.minusDays(it.toLong()) }.map { it to (byDay[it.toString()] ?: 0.0) }
    val buckets = mutableMapOf<String, Int>()
    reportQuery("SELECT PlaybackMethod, COUNT(*) FROM PlaybackActivity WHERE DateCreated >= $since30 GROUP BY PlaybackMethod").filter { it.size >= 2 }.forEach {
        val m = it[0].lowercase()
        val label = when { m.startsWith("directplay") -> "Direct Play"; m.startsWith("directstream") -> "Direct Stream"; m.contains("v:direct") -> "Remux"; else -> "Transcode" }
        buckets[label] = (buckets[label] ?: 0) + (it[1].toIntOrNull() ?: 0)
    }
    val methods = listOf("Direct Play", "Direct Stream", "Remux", "Transcode").mapNotNull { l -> buckets[l]?.let { l to it } }
    val users = reportQuery("SELECT UserId, SUM(PlayDuration), COUNT(*) FROM PlaybackActivity WHERE DateCreated >= $since30 GROUP BY UserId ORDER BY 2 DESC LIMIT 6")
        .filter { it.size >= 3 }.map { Triple(it[0], (it[1].toDoubleOrNull() ?: 0.0) / 3600, it[2].toIntOrNull() ?: 0) }
    val titles = reportQuery("SELECT ItemName, SUM(PlayDuration), COUNT(*) FROM PlaybackActivity WHERE DateCreated >= $since30 AND ItemType != 'Audio' GROUP BY ItemName ORDER BY 2 DESC LIMIT 6")
        .filter { it.size >= 3 }.map { Triple(it[0], (it[1].toDoubleOrNull() ?: 0.0) / 3600, it[2].toIntOrNull() ?: 0) }
    WatchStats(days, methods, users, titles)
}.getOrNull()
