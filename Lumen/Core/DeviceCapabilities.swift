import AVFoundation
import VideoToolbox

/// Describes what this device can play natively, and turns that into a Jellyfin DeviceProfile.
///
/// Strategy:
/// - MP4/MOV with HEVC/H.264 (incl. Dolby Vision 5/8, HDR10, HLG) and AAC/AC3/E-AC3 (Atmos) → Direct Play.
/// - MKV or unsupported audio (TrueHD, DTS) → HLS with fMP4 segments. Video is copied untouched
///   (still DV/HDR), and only the audio is converted when needed. This is "Direct Stream".
/// - Only if the video itself can't play is it re-encoded (Transcode).
enum DeviceCapabilities {
    static let hevc: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    static let av1: Bool = VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) // 'av01'
    static let dolbyVision: Bool = AVPlayer.availableHDRModes.contains(.dolbyVision)
    static let hdr10: Bool = AVPlayer.availableHDRModes.contains(.hdr10)
    static let hlg: Bool = AVPlayer.availableHDRModes.contains(.hlg)

    static var supportedRangeTypes: [String] {
        var ranges = ["SDR"]
        if hdr10 { ranges += ["HDR10", "HDR10Plus"] }
        if hlg { ranges.append("HLG") }
        // Profile 5 / 8.x. Profile 7 (dual-layer UHD Blu-ray) is deliberately NOT listed: Apple can't
        // decode it, so the server falls back to the HDR10 base layer.
        if dolbyVision { ranges += ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR", "DOVIWithHDR10Plus"] }
        return ranges
    }

    /// What AirPlay receivers such as car screens reliably decode: 1080p H.264 SDR with stereo AAC over HLS.
    static func airPlayProfile(maxBitrate: Int) -> [String: Any] {
        typealias J = [String: Any]
        return [
            "Name": "Huefin AirPlay",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "DirectPlayProfiles": [J](),
            "TranscodingProfiles": [
                ["Type": "Video", "Container": "ts", "Protocol": "hls", "Context": "Streaming",
                 "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2",
                 "BreakOnNonKeyFrames": true, "MinSegments": 1] as J,
            ] as [J],
            "ContainerProfiles": [J](),
            "CodecProfiles": [
                ["Type": "Video", "Codec": "h264", "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": "SDR", "IsRequired": true] as J,
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "41", "IsRequired": true] as J,
                    ["Condition": "LessThanEqual", "Property": "Height", "Value": "1080", "IsRequired": true] as J,
                    ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": true] as J,
                ] as [J]] as J,
            ] as [J],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "Hls"], ["Format": "subrip", "Method": "Hls"],
                ["Format": "srt", "Method": "Hls"],
            ] as [J],
        ]
    }

    static func deviceProfile(maxBitrate: Int) -> [String: Any] {
        var directVideo = ["h264"]
        if hevc { directVideo.append("hevc") }
        if av1 { directVideo.append("av1") }

        // First codec is the re-encode target if a real transcode is needed; others are copied as-is.
        var hlsVideo = ["h264"]
        if hevc { hlsVideo.append("hevc") }

        let directAudio = "aac,ac3,eac3,alac,flac,mp3"
        let hlsAudio = "eac3,ac3,aac,mp3"
        let ranges = supportedRangeTypes.joined(separator: "|")

        typealias J = [String: Any]

        func rangeCondition(_ value: String) -> J {
            ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": value, "IsRequired": false]
        }

        var codecProfiles: [J] = [
            ["Type": "Video", "Codec": "hevc", "Conditions": [rangeCondition(ranges)] as [J]] as J,
            ["Type": "Video", "Codec": "h264", "Conditions": [
                rangeCondition("SDR"),
                ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "52", "IsRequired": false] as J,
            ] as [J]] as J,
        ]
        if av1 {
            codecProfiles.append(["Type": "Video", "Codec": "av1",
                                  "Conditions": [rangeCondition("SDR|HDR10|HDR10Plus|HLG")] as [J]] as J)
        }

        let directPlay: [J] = [
            ["Type": "Video", "Container": "mp4,m4v,mov",
             "VideoCodec": directVideo.joined(separator: ","), "AudioCodec": directAudio] as J,
            ["Type": "Audio", "Container": "mp3,aac,m4a,m4b,flac,alac,wav"] as J,
        ]

        let transcoding: [J] = [
            ["Type": "Video", "Container": "mp4", "Protocol": "hls", "Context": "Streaming",
             "VideoCodec": hlsVideo.joined(separator: ","), "AudioCodec": hlsAudio,
             "MaxAudioChannels": "8", "BreakOnNonKeyFrames": true, "MinSegments": 1] as J,
            ["Type": "Audio", "Container": "aac", "Protocol": "http", "Context": "Streaming",
             "AudioCodec": "aac", "MaxAudioChannels": "6"] as J,
        ]

        let subtitles: [J] = [
            ["Format": "vtt", "Method": "Hls"],
            ["Format": "subrip", "Method": "Hls"],
            ["Format": "srt", "Method": "Hls"],
            ["Format": "ass", "Method": "Hls"],
            ["Format": "ssa", "Method": "Hls"],
            ["Format": "mov_text", "Method": "Embed"],
        ]

        let profile: J = [
            "Name": "Huefin iOS",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "MusicStreamingTranscodingBitrate": 384_000,
            "DirectPlayProfiles": directPlay,
            "TranscodingProfiles": transcoding,
            "ContainerProfiles": [J](),
            "CodecProfiles": codecProfiles,
            "SubtitleProfiles": subtitles,
            "ResponseProfiles": [["Type": "Video", "Container": "m4v", "MimeType": "video/mp4"]] as [J],
        ]
        return profile
    }
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
    return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
}
