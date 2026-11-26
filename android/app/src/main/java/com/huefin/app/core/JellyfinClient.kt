package com.huefin.app.core

import com.huefin.app.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant
import java.util.concurrent.TimeUnit

class HttpError(val code: Int) : Exception(
    when (code) {
        401 -> "Wrong username or password, or your session expired."
        403 -> "The server said no (403)."
        404 -> "Not found on the server."
        else -> "Server error (HTTP $code)."
    }
)

/** The Jellyfin REST API (server 10.9+). */
class JellyfinClient(val baseUrl: String, var accessToken: String? = null, var userId: String? = null) {
    companion object {
        const val CLIENT_NAME = "Huefin"
        val VERSION: String = BuildConfig.VERSION_NAME
        const val LIST_FIELDS = "PrimaryImageAspectRatio,Overview,Genres"
        const val SEARCH_TYPES = "Movie,Series,Episode,BoxSet,MusicArtist,MusicAlbum,Audio,Book,AudioBook,TvChannel,Playlist"
        const val LIVE_SEGMENT_LENGTH = 2
        const val LIVE_MIN_SEGMENTS = 4
        val http: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
        val deviceId: String get() = Prefs.deviceId
        val deviceName: String
            get() = android.os.Build.MODEL.filter { it.isLetterOrDigit() || it == ' ' || it == '-' }.ifBlank { "Android" }
    }

    val authHeader: String
        get() {
            var h = "MediaBrowser Client=\"$CLIENT_NAME\", Device=\"$deviceName\", DeviceId=\"$deviceId\", Version=\"$VERSION\""
            accessToken?.let { h += ", Token=\"$it\"" }
            return h
        }

    // MARK: Plumbing

    fun url(path: String, query: Map<String, String?> = emptyMap()): String {
        val b = (baseUrl.trimEnd('/') + "/" + path.trimStart('/')).toHttpUrl().newBuilder()
        query.toSortedMap().forEach { (k, v) -> if (v != null) b.addQueryParameter(k, v) }
        return b.build().toString()
    }

    suspend fun send(path: String, query: Map<String, String?> = emptyMap(), method: String = "POST",
                     body: JsonElement? = null): String = withContext(Dispatchers.IO) {
        val rb = when {
            body != null -> body.toString().toRequestBody("application/json".toMediaType())
            method == "POST" -> "".toRequestBody(null)
            method == "DELETE" -> null
            else -> null
        }
        val req = Request.Builder().url(url(path, query))
            .header("Authorization", authHeader)
            .header("Accept", "application/json")
            .method(method, rb).build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw HttpError(r.code)
            r.body?.string() ?: ""
        }
    }

    suspend inline fun <reified T> get(path: String, query: Map<String, String?> = emptyMap()): T =
        JellyfinJson.decodeFromString(send(path, query, "GET"))

    suspend inline fun <reified T> post(path: String, query: Map<String, String?> = emptyMap(), body: JsonElement): T =
        JellyfinJson.decodeFromString(send(path, query, "POST", body))

    // MARK: Server & auth

    suspend fun publicInfo(): PublicSystemInfo = get("System/Info/Public")
    suspend fun localAddress(): String? = runCatching { get<SystemInfo>("System/Info").localAddress }.getOrNull()

    suspend fun authenticate(username: String, password: String): AuthResult =
        post("Users/AuthenticateByName", body = buildJsonObject { put("Username", username); put("Pw", password) })

    suspend fun quickConnectEnabled(): Boolean = runCatching { send("QuickConnect/Enabled", method = "GET").trim() == "true" }.getOrDefault(false)
    suspend fun quickConnectInitiate(): QuickConnectState = JellyfinJson.decodeFromString(send("QuickConnect/Initiate"))
    suspend fun quickConnectState(secret: String): QuickConnectState = get("QuickConnect/Connect", mapOf("secret" to secret))
    suspend fun quickConnectAuthenticate(secret: String): AuthResult =
        post("Users/AuthenticateWithQuickConnect", body = buildJsonObject { put("Secret", secret) })
    suspend fun quickConnectAuthorize(code: String) { send("QuickConnect/Authorize", mapOf("code" to code, "userId" to userId)) }

    // MARK: Library

    suspend fun userViews(): List<BaseItem> = get<ItemsResult>("UserViews", mapOf("userId" to userId)).items
    suspend fun resume(): List<BaseItem> = get<ItemsResult>("UserItems/Resume", mapOf(
        "userId" to userId, "limit" to "20", "mediaTypes" to "Video",
        "fields" to LIST_FIELDS, "enableImageTypes" to "Primary,Backdrop,Thumb,Logo")).items
    suspend fun nextUp(seriesId: String? = null): List<BaseItem> = get<ItemsResult>("Shows/NextUp", mapOf(
        "userId" to userId, "limit" to "20", "seriesId" to seriesId, "fields" to LIST_FIELDS)).items
    suspend fun latest(parentId: String): List<BaseItem> = get("Items/Latest", mapOf(
        "userId" to userId, "parentId" to parentId, "limit" to "24", "fields" to LIST_FIELDS))

    suspend fun items(parentId: String?, types: String?, recursive: Boolean, sortBy: String, sortOrder: String,
                      start: Int, limit: Int, filters: String? = null, genres: String? = null): ItemsResult =
        get("Items", mapOf(
            "userId" to userId, "parentId" to parentId, "includeItemTypes" to types,
            "recursive" to recursive.toString(), "sortBy" to sortBy, "sortOrder" to sortOrder,
            "startIndex" to start.toString(), "limit" to limit.toString(), "fields" to LIST_FIELDS,
            "enableImageTypes" to "Primary,Backdrop,Thumb", "filters" to filters, "genres" to genres))

    suspend fun browse(q: Map<String, String?>): ItemsResult {
        val m = q.toMutableMap()
        m["userId"] = userId
        if (m["fields"] == null) m["fields"] = LIST_FIELDS
        return get("Items", m)
    }

    suspend fun genres(parentId: String?): List<String> = runCatching {
        get<ItemsResult>("Genres", mapOf("userId" to userId, "parentId" to parentId, "sortBy" to "SortName")).items.mapNotNull { it.name }
    }.getOrDefault(emptyList())

    suspend fun setFavorite(itemId: String, on: Boolean): Boolean =
        runCatching { send("UserFavoriteItems/$itemId", mapOf("userId" to userId), if (on) "POST" else "DELETE"); true }.getOrDefault(false)
    suspend fun markPlayed(itemId: String, played: Boolean = true) {
        runCatching { send("UserPlayedItems/$itemId", mapOf("userId" to userId), if (played) "POST" else "DELETE") }
    }

    suspend fun favorites(): List<BaseItem> = runCatching { browse(mapOf(
        "filters" to "IsFavorite", "includeItemTypes" to "Movie,Series", "recursive" to "true",
        "sortBy" to "DateCreated", "sortOrder" to "Descending", "limit" to "40",
        "enableImageTypes" to "Primary,Backdrop,Thumb")).items }.getOrDefault(emptyList())
    suspend fun collections(): List<BaseItem> = runCatching { browse(mapOf(
        "includeItemTypes" to "BoxSet", "recursive" to "true", "sortBy" to "SortName", "limit" to "60")).items }.getOrDefault(emptyList())
    suspend fun search(term: String): List<BaseItem> = browse(mapOf(
        "searchTerm" to term, "recursive" to "true", "includeItemTypes" to SEARCH_TYPES, "limit" to "120",
        "enableImageTypes" to "Primary,Backdrop,Thumb")).items
    suspend fun specialFeatures(itemId: String): List<BaseItem> =
        runCatching { get<List<BaseItem>>("Items/$itemId/SpecialFeatures", mapOf("userId" to userId)) }.getOrDefault(emptyList())
    suspend fun additionalParts(itemId: String): List<BaseItem> =
        runCatching { get<ItemsResult>("Videos/$itemId/AdditionalParts", mapOf("userId" to userId)).items }.getOrDefault(emptyList())
    suspend fun similar(itemId: String): List<BaseItem> = runCatching {
        get<ItemsResult>("Items/$itemId/Similar", mapOf("userId" to userId, "limit" to "16", "fields" to LIST_FIELDS)).items
    }.getOrDefault(emptyList())

    suspend fun item(id: String): BaseItem = get("Items/$id", mapOf("userId" to userId))
    suspend fun seasons(seriesId: String): List<BaseItem> = get<ItemsResult>("Shows/$seriesId/Seasons", mapOf("userId" to userId)).items
    suspend fun episodes(seriesId: String, seasonId: String): List<BaseItem> = get<ItemsResult>("Shows/$seriesId/Episodes", mapOf(
        "userId" to userId, "seasonId" to seasonId, "fields" to "$LIST_FIELDS,MediaSources", "enableUserData" to "true")).items
    suspend fun episodeAfter(ep: BaseItem): BaseItem? {
        val sid = ep.seriesId ?: return null
        return runCatching { get<ItemsResult>("Shows/$sid/Episodes", mapOf(
            "userId" to userId, "startItemId" to ep.id, "limit" to "2", "Fields" to LIST_FIELDS, "EnableUserData" to "true"))
            .items.firstOrNull { it.id != ep.id } }.getOrNull()
    }

    // MARK: Music & books

    suspend fun albumTracks(albumId: String): List<BaseItem> = browse(mapOf(
        "parentId" to albumId, "includeItemTypes" to "Audio", "sortBy" to "ParentIndexNumber,IndexNumber,SortName")).items
    suspend fun artistAlbums(artistId: String): List<BaseItem> = browse(mapOf(
        "artistIds" to artistId, "includeItemTypes" to "MusicAlbum", "recursive" to "true",
        "sortBy" to "ProductionYear,SortName", "sortOrder" to "Descending")).items
    suspend fun instantMix(itemId: String, limit: Int = 50): List<BaseItem> = get<ItemsResult>("Items/$itemId/InstantMix",
        mapOf("userId" to userId, "limit" to limit.toString(), "fields" to LIST_FIELDS)).items
    suspend fun musicGenres(parentId: String?): List<BaseItem> = get<ItemsResult>("MusicGenres", mapOf(
        "userId" to userId, "parentId" to parentId, "sortBy" to "SortName")).items
    suspend fun songs(parentId: String?, sortBy: String, sortOrder: String = "Descending", filters: String? = null,
                      genreIds: String? = null, limit: Int = 100): List<BaseItem> = runCatching { browse(mapOf(
        "parentId" to parentId, "includeItemTypes" to "Audio", "recursive" to "true", "sortBy" to sortBy,
        "sortOrder" to sortOrder, "filters" to filters, "genreIds" to genreIds, "limit" to limit.toString())).items }.getOrDefault(emptyList())
    suspend fun albumArtists(parentId: String, start: Int): ItemsResult = get("Artists/AlbumArtists", mapOf(
        "userId" to userId, "parentId" to parentId, "sortBy" to "SortName", "startIndex" to start.toString(), "limit" to "100",
        "fields" to "PrimaryImageAspectRatio"))
    suspend fun playlistItems(playlistId: String): List<BaseItem> = get<ItemsResult>("Playlists/$playlistId/Items",
        mapOf("userId" to userId, "fields" to LIST_FIELDS)).items
    fun audioURL(itemId: String): String = url("Audio/$itemId/universal", mapOf(
        "userId" to userId, "deviceId" to deviceId, "ApiKey" to accessToken, "maxStreamingBitrate" to "320000",
        "container" to "opus,mp3,aac,m4a,flac,ogg,wav", "transcodingContainer" to "aac", "audioCodec" to "aac",
        "transcodingProtocol" to "http"))

    // MARK: Live TV

    suspend fun liveChannels(): List<BaseItem> = get<ItemsResult>("LiveTv/Channels", mapOf(
        "userId" to userId, "addCurrentProgram" to "true", "enableImageTypes" to "Primary,Thumb",
        "fields" to "PrimaryImageAspectRatio,ChannelInfo", "limit" to "1000")).items
    suspend fun liveGuide(hours: Double = 6.0): Map<String, List<ProgramInfo>> {
        val now = Instant.now()
        val r: ProgramsResult = get("LiveTv/Programs", mapOf(
            "userId" to userId, "minEndDate" to now.toString(),
            "maxStartDate" to now.plusSeconds((hours * 3600).toLong()).toString(),
            "sortBy" to "StartDate", "limit" to "3000", "enableImages" to "false"))
        return r.items.groupBy { it.channelId ?: "" }
    }
    suspend fun closeLiveStream(id: String) { runCatching { send("LiveTv/LiveStreams/Close", mapOf("liveStreamId" to id)) } }

    // MARK: Playback

    suspend fun playbackInfo(itemId: String, maxBitrate: Int, profile: JsonObject, startTicks: Long = 0,
                             audioStreamIndex: Int? = null, subtitleStreamIndex: Int? = -1,
                             mediaSourceId: String? = null, enableDirectPlay: Boolean = true): PlaybackInfoResponse {
        val body = buildJsonObject {
            put("UserId", userId ?: "")
            put("DeviceProfile", profile)
            put("MaxStreamingBitrate", maxBitrate)
            put("StartTimeTicks", startTicks)
            put("EnableDirectPlay", enableDirectPlay)
            put("EnableDirectStream", true)
            put("EnableTranscoding", true)
            put("AllowVideoStreamCopy", true)
            put("AllowAudioStreamCopy", true)
            put("AutoOpenLiveStream", true)
            audioStreamIndex?.let { put("AudioStreamIndex", it) }
            subtitleStreamIndex?.let { put("SubtitleStreamIndex", it) }
            mediaSourceId?.let { put("MediaSourceId", it) }
        }
        return post("Items/$itemId/PlaybackInfo", mapOf(
            "userId" to userId, "maxStreamingBitrate" to maxBitrate.toString(), "startTimeTicks" to startTicks.toString(),
            "audioStreamIndex" to audioStreamIndex?.toString(), "subtitleStreamIndex" to subtitleStreamIndex?.toString(),
            "mediaSourceId" to mediaSourceId), body)
    }

    fun directPlayURL(itemId: String, mediaSourceId: String, container: String?): String {
        val ext = container?.split(",")?.firstOrNull() ?: "mp4"
        return url("Videos/$itemId/stream.$ext", mapOf("static" to "true", "mediaSourceId" to mediaSourceId,
            "deviceId" to deviceId, "ApiKey" to accessToken))
    }
    fun originalDownloadURL(itemId: String) = url("Items/$itemId/Download", mapOf("ApiKey" to accessToken))

    fun liveHLSURL(channelId: String, mediaSourceId: String, liveStreamId: String?, playSessionId: String?, maxBitrate: Int,
                   hevc: Boolean): String = url("Videos/$channelId/master.m3u8", mapOf(
        "MediaSourceId" to mediaSourceId, "LiveStreamId" to liveStreamId, "PlaySessionId" to playSessionId,
        "DeviceId" to deviceId, "VideoCodec" to if (hevc) "h264,hevc" else "h264", "AudioCodec" to "aac,eac3,ac3,mp3",
        "SegmentContainer" to "ts", "SegmentLength" to LIVE_SEGMENT_LENGTH.toString(),
        "MinSegments" to LIVE_MIN_SEGMENTS.toString(), "BreakOnNonKeyFrames" to "false",
        "TranscodingMaxAudioChannels" to "6", "MaxStreamingBitrate" to maxBitrate.toString(),
        "AllowVideoStreamCopy" to "true", "AllowAudioStreamCopy" to "true", "RequireAvc" to "false", "ApiKey" to accessToken))

    /** Server-relative paths (TranscodingUrl) → absolute, with the key attached and subtitle burn-in removed. */
    fun absoluteURL(serverRelative: String, live: Boolean = false): String {
        var path = removingSubtitleBurnIn(serverRelative)
        if (live) path = tuningLive(path)
        var full = baseUrl.trimEnd('/') + (if (path.startsWith("/")) path else "/$path")
        val lower = full.lowercase()
        if (!lower.contains("api_key=") && !lower.contains("apikey=") && accessToken != null) {
            full += (if (full.contains("?")) "&" else "?") + "ApiKey=$accessToken"
        }
        return full
    }

    private fun splitQuery(path: String): Pair<String, MutableList<Pair<String, String>>> {
        val i = path.indexOf('?')
        if (i < 0) return path to mutableListOf()
        val items = path.substring(i + 1).split("&").filter { it.isNotEmpty() }.map {
            val j = it.indexOf('='); if (j < 0) it to "" else it.substring(0, j) to it.substring(j + 1)
        }.toMutableList()
        return path.substring(0, i) to items
    }
    private fun join(base: String, items: List<Pair<String, String>>) =
        if (items.isEmpty()) base else base + "?" + items.joinToString("&") { "${it.first}=${it.second}" }

    fun removingSubtitleBurnIn(path: String): String {
        val (base, items) = splitQuery(path)
        if (items.none { it.first.equals("SubtitleMethod", true) && it.second.equals("Encode", true) }) return path
        val drop = setOf("subtitlemethod", "subtitlestreamindex", "subtitlecodec")
        return join(base, items.filter { it.first.lowercase() !in drop })
    }
    private fun tuningLive(path: String): String {
        val (base, items) = splitQuery(path)
        val set = setOf("segmentlength", "minsegments", "breakonnonkeyframes")
        val kept = items.filter { it.first.lowercase() !in set }.toMutableList()
        kept += listOf("SegmentLength" to LIVE_SEGMENT_LENGTH.toString(), "MinSegments" to LIVE_MIN_SEGMENTS.toString(),
            "BreakOnNonKeyFrames" to "false")
        return join(base, kept)
    }

    suspend fun reportPlayback(path: String, body: JsonObject) { runCatching { send(path, body = body) } }
    suspend fun stopEncoding(playSessionId: String) {
        runCatching { send("Videos/ActiveEncodings", mapOf("deviceId" to deviceId, "playSessionId" to playSessionId), "DELETE") }
    }
    suspend fun updateUserData(itemId: String, positionTicks: Long, played: Boolean): Boolean {
        val body = buildJsonObject {
            put("PlaybackPositionTicks", positionTicks); put("Played", played); put("LastPlayedDate", Instant.now().toString())
        }
        if (runCatching { send("UserItems/$itemId/UserData", mapOf("userId" to userId), body = body) }.isSuccess) return true
        return runCatching { send("Sessions/Playing/Stopped", body = buildJsonObject {
            put("ItemId", itemId); put("PositionTicks", positionTicks); put("CanSeek", true) }) }.isSuccess
    }

    suspend fun mediaSegments(itemId: String): List<MediaSegment> =
        runCatching { get<MediaSegmentsResult>("MediaSegments/$itemId").items }.getOrDefault(emptyList())
    suspend fun playbackExtras(itemId: String): PlaybackExtras =
        runCatching { get<PlaybackExtras>("Users/${userId ?: ""}/Items/$itemId", mapOf("Fields" to "Chapters,Trickplay")) }
            .getOrDefault(PlaybackExtras())
    fun trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String) =
        url("Videos/$itemId/Trickplay/$width/$index.jpg", mapOf("mediaSourceId" to mediaSourceId, "ApiKey" to accessToken))

    suspend fun searchSubtitles(itemId: String, language: String): List<RemoteSubtitleInfo> =
        get("Items/$itemId/RemoteSearch/Subtitles/$language", mapOf("isPerfectMatch" to "false"))
    suspend fun downloadSubtitle(itemId: String, subtitleId: String) { send("Items/$itemId/RemoteSearch/Subtitles/$subtitleId") }

    // MARK: Images

    fun imageURL(itemId: String, type: String = "Primary", maxWidth: Int = 400, tag: String? = null) =
        url("Items/$itemId/Images/$type", mapOf("maxWidth" to maxWidth.toString(), "quality" to "90", "tag" to tag))
    fun posterURL(item: BaseItem, width: Int = 400): String =
        if (item.type == "Episode" && item.seriesId != null) imageURL(item.seriesId, maxWidth = width, tag = item.seriesPrimaryImageTag)
        else imageURL(item.id, maxWidth = width, tag = item.imageTag("Primary"))
    fun landscapeURL(item: BaseItem, width: Int = 700): String =
        if (item.type == "Episode") imageURL(item.id, maxWidth = width, tag = item.imageTag("Primary")) else backdropURL(item, width)
    fun backdropURL(item: BaseItem, width: Int = 1600): String {
        item.backdropImageTags?.firstOrNull()?.let { return imageURL(item.id, "Backdrop/0", width, it) }
        val pid = item.parentBackdropItemId
        val ptag = item.parentBackdropImageTags?.firstOrNull()
        if (pid != null && ptag != null) return imageURL(pid, "Backdrop/0", width, ptag)
        item.imageTag("Thumb")?.let { return imageURL(item.id, "Thumb", width, it) }
        return imageURL(item.id, maxWidth = width, tag = item.imageTag("Primary"))
    }
    fun logoURL(item: BaseItem): String? {
        item.imageTag("Logo")?.let { return imageURL(item.id, "Logo", 600, it) }
        return item.parentLogoItemId?.let { imageURL(it, "Logo", 600, item.parentLogoImageTag) }
    }
    fun albumArtURL(item: BaseItem, width: Int = 600): String {
        if (item.imageTag("Primary") != null) return imageURL(item.id, maxWidth = width, tag = item.imageTag("Primary"))
        item.albumId?.let { return imageURL(it, maxWidth = width, tag = item.albumPrimaryImageTag) }
        return imageURL(item.id, maxWidth = width)
    }
    fun userImageURL(id: String) = url("Users/$id/Images/Primary", mapOf("maxWidth" to "300"))
}

fun JsonElement.objOrNull(): JsonObject? = runCatching { jsonObject }.getOrNull()
inline fun <reified T> JsonElement.decode(): T = JellyfinJson.decodeFromJsonElement(this)
