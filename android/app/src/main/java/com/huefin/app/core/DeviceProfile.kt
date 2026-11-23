package com.huefin.app.core

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecList
import android.view.Display
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * What this device can play, as a Jellyfin DeviceProfile.
 *
 * ExoPlayer opens MKV/MP4/WebM directly, and the bundled FFmpeg decoder handles AC-3/E-AC-3/TrueHD/DTS,
 * so nearly everything is Direct Play. Dolby Vision Profile 8 files play their HDR10 base layer on devices
 * without a DV decoder (like Pixels), so they're still played untouched instead of re-encoded.
 */
object DeviceProfile {
    data class Capabilities(
        val hevc: Boolean,
        val av1: Boolean,
        val vp9: Boolean,
        val dolbyVisionDecoder: Boolean,
        val hdr10: Boolean,
        val hdr10Plus: Boolean,
        val hlg: Boolean,
        val dolbyVisionDisplay: Boolean,
        val ac3: Boolean,
        val eac3: Boolean,
    )

    @Volatile private var cached: Capabilities? = null

    fun capabilities(context: Context): Capabilities {
        cached?.let { return it }
        val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder }
            .flatMap { it.supportedTypes.toList() }
            .map { it.lowercase() }
            .toSet()
        val display = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)
        @Suppress("DEPRECATION")
        val hdrTypes = display?.hdrCapabilities?.supportedHdrTypes?.toSet() ?: emptySet()
        val caps = Capabilities(
            hevc = "video/hevc" in decoders,
            av1 = "video/av01" in decoders,
            vp9 = "video/x-vnd.on2.vp9" in decoders,
            dolbyVisionDecoder = "video/dolby-vision" in decoders,
            hdr10 = Display.HdrCapabilities.HDR_TYPE_HDR10 in hdrTypes,
            hdr10Plus = Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS in hdrTypes,
            hlg = Display.HdrCapabilities.HDR_TYPE_HLG in hdrTypes,
            dolbyVisionDisplay = Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION in hdrTypes,
            ac3 = "audio/ac3" in decoders,
            eac3 = "audio/eac3" in decoders,
        )
        cached = caps
        return caps
    }

    fun build(context: Context, maxBitrate: Int): JsonObject {
        val c = capabilities(context)
        val video = buildList {
            add("h264")
            if (c.hevc) add("hevc")
            if (c.vp9) add("vp9")
            if (c.av1) add("av1")
        }.joinToString(",")
        // What Android decodes itself. DTS and TrueHD go to the Huefin Engine (VLC) instead of the server.
        val audio = buildList {
            addAll(listOf("aac", "mp3", "mp2", "opus", "vorbis", "flac", "alac", "pcm_s16le", "pcm_s24le"))
            if (c.ac3) add("ac3")
            if (c.eac3) add("eac3")
        }.joinToString(",")

        val ranges = buildList {
            add("SDR")
            if (c.hdr10 || c.hdr10Plus) { add("HDR10"); add("HDR10Plus") }
            if (c.hlg) add("HLG")
            // DV with an HDR10/HLG/SDR-compatible base layer plays that base layer without a DV decoder.
            add("DOVIWithHDR10"); add("DOVIWithHLG"); add("DOVIWithSDR"); add("DOVIWithHDR10Plus")
            // Profile 5 (no compatible base layer) needs a real DV decoder.
            if (c.dolbyVisionDecoder) add("DOVI")
        }.joinToString("|")

        fun rangeCondition(value: String) = buildJsonObject {
            put("Condition", "EqualsAny"); put("Property", "VideoRangeType"); put("Value", value); put("IsRequired", false)
        }

        return buildJsonObject {
            put("Name", "Huefin Android")
            put("MaxStreamingBitrate", maxBitrate)
            put("MaxStaticBitrate", maxBitrate)
            put("MusicStreamingTranscodingBitrate", 384_000)
            put("DirectPlayProfiles", buildJsonArray {
                add(buildJsonObject {
                    put("Type", "Video"); put("Container", "mkv,webm,mp4,m4v,mov,ts,m2ts")
                    put("VideoCodec", video); put("AudioCodec", audio)
                })
                add(buildJsonObject { put("Type", "Audio"); put("Container", "mp3,aac,m4a,flac,ogg,opus,wav") })
            })
            put("TranscodingProfiles", buildJsonArray {
                add(buildJsonObject {
                    put("Type", "Video"); put("Container", "ts"); put("Protocol", "hls"); put("Context", "Streaming")
                    put("VideoCodec", if (c.hevc) "h264,hevc" else "h264"); put("AudioCodec", if (c.eac3) "aac,eac3,ac3,mp3" else "aac,mp3")
                    put("MaxAudioChannels", "8"); put("BreakOnNonKeyFrames", true); put("MinSegments", 1)
                })
            })
            put("ContainerProfiles", JsonArray(emptyList()))
            put("CodecProfiles", buildJsonArray {
                add(buildJsonObject {
                    put("Type", "Video"); put("Codec", "hevc"); put("Conditions", JsonArray(listOf(rangeCondition(ranges))))
                })
                add(buildJsonObject {
                    put("Type", "Video"); put("Codec", "av1")
                    put("Conditions", JsonArray(listOf(rangeCondition("SDR|HDR10|HDR10Plus|HLG"))))
                })
                add(buildJsonObject {
                    put("Type", "Video"); put("Codec", "h264"); put("Conditions", JsonArray(listOf(rangeCondition("SDR"))))
                })
            })
            put("SubtitleProfiles", buildJsonArray {
                for (f in listOf("srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgssub", "dvdsub", "dvbsub", "mov_text")) {
                    add(buildJsonObject { put("Format", f); put("Method", "Embed") })
                }
                for (f in listOf("srt", "subrip", "ass", "ssa", "vtt")) {
                    add(buildJsonObject { put("Format", f); put("Method", "External") })
                }
            })
        }
    }

    fun describe(context: Context): List<Pair<String, String>> {
        val c = capabilities(context)
        fun yes(b: Boolean) = if (b) "Yes" else "No"
        return listOf(
            "Dolby Vision decoder" to (if (c.dolbyVisionDecoder) "Yes" else "No (plays HDR10 layer of DV files)"),
            "HDR10 display" to yes(c.hdr10),
            "HDR10+ display" to yes(c.hdr10Plus),
            "HLG display" to yes(c.hlg),
            "HEVC decoder" to yes(c.hevc),
            "AV1 decoder" to yes(c.av1),
            "Dolby Digital" to yes(c.ac3 || c.eac3),
            "DTS / TrueHD" to "Huefin Engine",
        )
    }
}
