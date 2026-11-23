package com.huefin.app.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import java.time.Instant
import java.time.OffsetDateTime

/** Jellyfin speaks PascalCase JSON; our Kotlin fields are camelCase. */
@OptIn(ExperimentalSerializationApi::class)
val JellyfinJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    isLenient = true
    namingStrategy = object : JsonNamingStrategy {
        override fun serialNameForJson(descriptor: SerialDescriptor, elementIndex: Int, serialName: String) =
            serialName.replaceFirstChar { it.uppercase() }
    }
}

@Serializable data class PublicSystemInfo(val serverName: String? = null, val version: String? = null, val id: String? = null)
@Serializable data class SystemInfo(val localAddress: String? = null, val id: String? = null)
@Serializable data class UserDto(val id: String, val name: String)
@Serializable data class AuthResult(val user: UserDto, val accessToken: String, val serverId: String? = null)
@Serializable data class QuickConnectState(val secret: String, val code: String? = null, val authenticated: Boolean? = null)
@Serializable data class ItemsResult(val items: List<BaseItem> = emptyList(), val totalRecordCount: Int? = null)
@Serializable data class NameId(val name: String? = null, val id: String)
@Serializable data class ProgramsResult(val items: List<ProgramInfo> = emptyList())

@Serializable
data class UserItemData(
    val playbackPositionTicks: Long? = null,
    val played: Boolean? = null,
    val playedPercentage: Double? = null,
    val isFavorite: Boolean? = null,
    val unplayedItemCount: Int? = null,
)

@Serializable
data class MediaStream(
    val type: String? = null,
    val index: Int? = null,
    val codec: String? = null,
    val profile: String? = null,
    val displayTitle: String? = null,
    val title: String? = null,
    val language: String? = null,
    val channels: Int? = null,
    val channelLayout: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val bitRate: Int? = null,
    val bitDepth: Int? = null,
    val videoRange: String? = null,
    val videoRangeType: String? = null,
    val audioSpatialFormat: String? = null,
    val isDefault: Boolean? = null,
    val isForced: Boolean? = null,
    val isExternal: Boolean? = null,
) {
    val isAtmos: Boolean
        get() = (profile ?: "").contains("atmos", true) || (displayTitle ?: "").contains("atmos", true) ||
            audioSpatialFormat == "DolbyAtmos"
}

@Serializable
data class RemoteSubtitleInfo(
    val id: String,
    val name: String? = null,
    val providerName: String? = null,
    val format: String? = null,
    val downloadCount: Int? = null,
    val threeLetterISOLanguageName: String? = null,
)

@Serializable
data class MediaSource(
    val id: String,
    val name: String? = null,
    val container: String? = null,
    val size: Long? = null,
    val bitrate: Int? = null,
    val runTimeTicks: Long? = null,
    val supportsDirectPlay: Boolean? = null,
    val supportsDirectStream: Boolean? = null,
    val supportsTranscoding: Boolean? = null,
    val transcodingUrl: String? = null,
    val liveStreamId: String? = null,
    val defaultAudioStreamIndex: Int? = null,
    val defaultSubtitleStreamIndex: Int? = null,
    val mediaStreams: List<MediaStream>? = null,
) {
    val videoStream get() = mediaStreams?.firstOrNull { it.type == "Video" }
    val audioStreams get() = mediaStreams?.filter { it.type == "Audio" } ?: emptyList()
    val subtitleStreams get() = mediaStreams?.filter { it.type == "Subtitle" } ?: emptyList()
    val badges: List<String>
        get() = buildList {
            videoStream?.let { v ->
                val w = v.width ?: 0; val h = v.height ?: 0
                if (w >= 3200 || h >= 2000) add("4K") else if (w >= 1900 || h >= 1000) add("HD")
                val r = v.videoRangeType ?: v.videoRange ?: ""
                when {
                    r.contains("DOVI") -> add("Dolby Vision")
                    r.contains("HDR10Plus") -> add("HDR10+")
                    r.contains("HDR10") || r == "HDR" -> add("HDR10")
                    r.contains("HLG") -> add("HLG")
                }
            }
            if (audioStreams.any { it.isAtmos }) add("Atmos")
        }
}

@Serializable
data class PlaybackInfoResponse(val mediaSources: List<MediaSource> = emptyList(), val playSessionId: String? = null, val errorCode: String? = null)

@Serializable
data class TranscodingInfo(
    val audioCodec: String? = null, val videoCodec: String? = null, val container: String? = null,
    val isVideoDirect: Boolean? = null, val isAudioDirect: Boolean? = null, val bitrate: Int? = null,
    val width: Int? = null, val height: Int? = null,
)

@Serializable
data class ProgramInfo(
    val id: String,
    val name: String? = null,
    val episodeTitle: String? = null,
    val overview: String? = null,
    val channelId: String? = null,
    val startDate: String? = null,
    val endDate: String? = null,
) {
    val start: Instant? get() = startDate?.let(::parseJellyfinDate)
    val end: Instant? get() = endDate?.let(::parseJellyfinDate)
    fun progress(now: Instant = Instant.now()): Double? {
        val s = start ?: return null; val e = end ?: return null
        if (!e.isAfter(s)) return null
        return ((now.toEpochMilli() - s.toEpochMilli()).toDouble() / (e.toEpochMilli() - s.toEpochMilli())).coerceIn(0.0, 1.0)
    }
}

fun parseJellyfinDate(s: String): Instant? = try {
    var t = s
    if (!t.endsWith("Z") && !t.contains("+") && t.count { it == '-' } <= 2) t += "Z"
    OffsetDateTime.parse(t).toInstant()
} catch (e: Exception) {
    try { Instant.parse(s) } catch (e: Exception) { null }
}

@Serializable
data class BaseItem(
    val id: String,
    val name: String? = null,
    val type: String? = null,
    val overview: String? = null,
    val productionYear: Int? = null,
    val runTimeTicks: Long? = null,
    val officialRating: String? = null,
    val communityRating: Double? = null,
    val seriesName: String? = null,
    val seriesId: String? = null,
    val seasonId: String? = null,
    val indexNumber: Int? = null,
    val parentIndexNumber: Int? = null,
    val collectionType: String? = null,
    val imageTags: Map<String, String>? = null,
    val backdropImageTags: List<String>? = null,
    val parentBackdropItemId: String? = null,
    val parentBackdropImageTags: List<String>? = null,
    val parentLogoItemId: String? = null,
    val parentLogoImageTag: String? = null,
    val seriesPrimaryImageTag: String? = null,
    val userData: UserItemData? = null,
    val mediaSources: List<MediaSource>? = null,
    val genres: List<String>? = null,
    val mediaType: String? = null,
    val parentId: String? = null,
    val album: String? = null,
    val albumId: String? = null,
    val albumArtist: String? = null,
    val artists: List<String>? = null,
    val albumPrimaryImageTag: String? = null,
    val artistItems: List<NameId>? = null,
    val childCount: Int? = null,
    val channelNumber: String? = null,
    val currentProgram: ProgramInfo? = null,
    val path: String? = null,
) {
    val isPlayable get() = type in setOf("Movie", "Episode", "Video", "MusicVideo", "TvChannel")
    val isLiveChannel get() = type == "TvChannel"
    val isAudio get() = type == "Audio" || type == "AudioBook"
    val isSeries get() = type == "Series"
    val isBook get() = type == "Book"
    val artistLine get() = albumArtist ?: artists?.firstOrNull()
    fun imageTag(kind: String) = imageTags?.get(kind) ?: imageTags?.entries?.firstOrNull { it.key.equals(kind, true) }?.value
    val displayTitle get() = (if (type == "Episode") seriesName else null) ?: name ?: "Untitled"
    val episodeLabel: String?
        get() {
            if (type != "Episode") return null
            val code = listOfNotNull(parentIndexNumber?.let { "S$it" }, indexNumber?.let { "E$it" }).joinToString(":")
            return listOf(code, name ?: "").filter { it.isNotEmpty() }.joinToString(" · ")
        }
    val runtimeText get() = runTimeTicks?.let(::formatTicks)
    val progress: Double?
        get() {
            val pos = userData?.playbackPositionTicks ?: return null
            val total = runTimeTicks ?: return null
            if (total <= 0 || pos <= 0) return null
            return (pos.toDouble() / total).coerceAtMost(1.0)
        }
    val resumeTicks get() = userData?.playbackPositionTicks ?: 0L
}

fun formatTicks(ticks: Long): String {
    val minutes = (ticks / 600_000_000L).toInt()
    val h = minutes / 60; val m = minutes % 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = listOf("KB", "MB", "GB", "TB")
    var v = bytes.toDouble() / 1024; var i = 0
    while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
    return String.format("%.1f %s", v, units[i])
}

@Serializable data class MediaSegment(val type: String? = null, val startTicks: Long? = null, val endTicks: Long? = null) {
    val start get() = (startTicks ?: 0) / 10_000_000.0
    val end get() = (endTicks ?: 0) / 10_000_000.0
}
@Serializable data class MediaSegmentsResult(val items: List<MediaSegment> = emptyList())
@Serializable data class ChapterMarker(val startPositionTicks: Long? = null, val name: String? = null) {
    val start get() = (startPositionTicks ?: 0) / 10_000_000.0
}
@Serializable data class TrickplayInfo(
    val width: Int? = null, val height: Int? = null, val tileWidth: Int? = null, val tileHeight: Int? = null,
    val thumbnailCount: Int? = null, val interval: Int? = null,
)
@Serializable data class PlaybackExtras(
    val chapters: List<ChapterMarker>? = null,
    val trickplay: Map<String, Map<String, TrickplayInfo>>? = null,
)
