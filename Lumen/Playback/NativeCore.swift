import UIKit
import AVFoundation
import AVKit
import CoreMedia
import AudioToolbox
import VideoToolbox
#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libswresample)
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

// FFmpeg macros Swift can't import.
private let AV_NOPTS: Int64 = .min
private let AVERR_EOF: Int32 = -0x2046_4F45          // FFERRTAG('E','O','F',' ')
private let AVERR_EAGAIN: Int32 = -35                // AVERROR(EAGAIN) on Apple platforms

/// The layer Apple's own video pipeline draws into.
final class NativeVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The Huefin Engine's native core (Level 4).
///
/// Huefin reads the file itself with FFmpeg (no server repackaging) and hands the untouched video to Apple's own
/// decoder and display layer, exactly as Apple's player would:
/// - **Dolby Vision** Profiles 5 and 8 are labelled as Dolby Vision ('dvh1' with their configuration record), so the
///   screen or TV runs in real Dolby Vision. HDR10, HDR10+ and HLG show as HDR.
/// - **Dolby Digital Plus with Atmos** goes to Apple's audio system untouched, so Atmos reaches AirPods, HomePods,
///   soundbars and receivers. TrueHD, DTS-HD, FLAC and everything else are decoded losslessly to multichannel PCM.
/// - **Picture in Picture** works natively (the layer is Apple's).
/// - Subtitles (text and Blu-ray/DVD pictures) are decoded here and drawn by the app.
///
/// Anything it can't show as intended (Dolby Vision Profile 7, codecs Apple can't decode) is handed to mpv.
final class NativeCore: NSObject, EngineCore {
    let view = NativeVideoView()
    var videoView: UIView { view }
    var engineName: String { "native" }
    var isReady: Bool { true }
    var onPlaybackRestart: (() -> Void)?
    var onEnd: ((EngineEnd) -> Void)?
    var onVideoReconfig: (() -> Void)?

    private let layer: AVSampleBufferDisplayLayer
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let videoFeed = DispatchQueue(label: "app.huefin.native.video")
    private let audioFeed = DispatchQueue(label: "app.huefin.native.audio")
    private let subQueue = DispatchQueue(label: "app.huefin.native.subs", qos: .utility)

    // Everything below is shared between the main thread, the demux thread and the feeders: guarded by `lock`.
    private let lock = NSLock()
    private var videoQ: [CMSampleBuffer] = []
    private var audioQ: [CMSampleBuffer] = []
    private var videoBytes = 0
    private var videoWaiting = false
    private var audioWaiting = false
    private var lastQueuedAudio = 0.0
    private var lastQueuedVideo = 0.0
    private var eof = false
    private var pendingSeek: Double?
    private var demuxRunning = false
    private var audioStreamIndex: Int32 = -1
    private var subStreamIndex: Int32 = -1
    private var cues: [Int32: [Cue]] = [:]
    private var trackList: (audio: [EngineTrack], subs: [EngineTrack]) = ([], [])
    private var externalSubs: [(id: Int32, name: String)] = []
    private var reopenAudio = false
    private var noPassthrough = false

    // Main-thread state.
    private enum Phase { case idle, starting(Double), playing, buffering, ended }
    private var phase: Phase = .idle
    private var userPaused = false
    private var rate: Float = 1
    private var durationSeconds = 0.0
    private var clock: Timer?
    private var demuxThread: Thread?
    private var demuxDone = DispatchSemaphore(value: 0)
    private var startedOnce = false
    private var passthroughFailed = false
    private var currentURL: URL?
    private var pendingExternal: [(URL, String, String?)] = []
    private(set) var videoFormat: CMVideoFormatDescription?
    private var frameRate: Float = 0
    private var dvProfile: Int = 0
    private var hdrLabel = "SDR"
    private var audioLabel = ""

    struct Cue { let start: Double; var end: Double; let content: EngineSubtitle }

    override init() {
        layer = view.displayLayer
        super.init()
        sync.addRenderer(layer)
        sync.addRenderer(audioRenderer)
        audioRenderer.audioTimePitchAlgorithm = .spectral
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit { destroy() }

    // MARK: - Eligibility

    /// Whether the native core can show this file as intended. Checked again (more precisely) once the file is open.
    static func canPlay(_ src: MediaSource?) -> Bool {
        guard EnginePrefs.nativeEnabled, let src, let v = src.mediaStreams?.first(where: { $0.type == "Video" }) else { return false }
        let codec = (v.codec ?? "").lowercased()
        guard codec == "hevc" || codec == "h264" else { return false }
        let containers = (src.container ?? "").lowercased().split(separator: ",").map(String.init)
        guard containers.contains(where: { ["mkv", "matroska", "webm", "mp4", "m4v", "mov"].contains($0) }) else { return false }
        let range = v.videoRangeType ?? ""
        if range.contains("WithEL") || v.dvProfile == 7 { return false }   // Profile 7 (dual layer): mpv
        if codec == "hevc" && !DeviceCapabilities.hevc { return false }
        if range == "DOVI" && !DeviceCapabilities.dolbyVision { return false }   // Profile 5 needs a DV decoder
        return true
    }

    // MARK: - Loading

    func load(_ url: URL, start: Double) {
        teardown()
        currentURL = url
        lock.lock()
        videoQ = []; audioQ = []; videoBytes = 0; eof = false; pendingSeek = nil
        lastQueuedAudio = start; lastQueuedVideo = start
        cues = [:]; externalSubs = []
        lock.unlock()
        phase = .starting(start)
        startedOnce = false
        sync.setRate(0, time: CMTime(seconds: start, preferredTimescale: 90_000))
        demuxDone = DispatchSemaphore(value: 0)
        lock.lock(); demuxRunning = true; lock.unlock()
        let t = Thread { [weak self] in self?.demuxMain(url: url, start: start) }
        t.name = "huefin-native-demux"
        t.qualityOfService = .userInitiated
        demuxThread = t
        t.start()
        startClock()
        for (u, title, lang) in pendingExternal { loadExternalSubtitle(u, title: title, lang: lang) }
        pendingExternal = []
    }

    private func teardown() {
        lock.lock(); let wasRunning = demuxRunning; demuxRunning = false; lock.unlock()
        if wasRunning { _ = demuxDone.wait(timeout: .now() + 3) }
        demuxThread = nil
        layer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        videoFeed.sync { layer.flush() }
        audioFeed.sync { audioRenderer.flush() }
    }

    func destroy() {
        clock?.invalidate(); clock = nil
        NotificationCenter.default.removeObserver(self)
        teardown()
        sync.setRate(0, time: .zero)
        phase = .idle
    }

    func stop() { destroy() }

    // MARK: - Demuxing (its own thread; the only place FFmpeg's file context is touched)

    private func running() -> Bool { lock.lock(); defer { lock.unlock() }; return demuxRunning }

    private func demuxMain(url: URL, start: Double) {
        defer { demuxDone.signal() }
        var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var opts: OpaquePointer? = nil
        for (k, v) in [("reconnect", "1"), ("reconnect_streamed", "1"), ("reconnect_on_network_error", "1"),
                       ("reconnect_delay_max", "4"), ("rw_timeout", "30000000"), ("user_agent", "Huefin")] {
            av_dict_set(&opts, k, v, 0)
        }
        let path = url.isFileURL ? url.path : url.absoluteString
        let openResult = avformat_open_input(&fmt, path, nil, &opts)
        av_dict_free(&opts)
        guard openResult >= 0, let ctx = fmt else { fail("Couldn't open the file (\(openResult)).", fallback: true, at: start); return }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { fail("Couldn't read the file.", fallback: true, at: start); return }

        let videoIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, let vStream = ctx.pointee.streams[Int(videoIndex)],
              let prepared = Self.prepareVideo(ctx, vStream, videoIndex),
              let format = makeVideoFormat(vStream, config: prepared.config),
              // Pre-flight: Apple's decoder must turn the first keyframe into a picture before we commit to it.
              // Anything it can't show (odd tags, missing setup data, unusual profiles) goes to mpv instead of
              // playing sound over a black screen.
              Self.decodesFirstFrame(format, keyframe: prepared.keyframe)
        else { fail("", fallback: true, at: start); return }
        // Back to the beginning after peeking at the first frames (the start position is applied below).
        av_seek_frame(ctx, -1, 0, AVSEEK_FLAG_BACKWARD)
        let durUs = ctx.pointee.duration
        let fps = vStream.pointee.avg_frame_rate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoFormat = format
            self.durationSeconds = durUs > 0 ? Double(durUs) / 1_000_000 : 0
            self.frameRate = fps.den > 0 ? Float(fps.num) / Float(fps.den) : 0
            self.onVideoReconfig?()
        }

        // Tracks.
        var audioTracks: [EngineTrack] = [], subTracks: [EngineTrack] = []
        let bestAudio = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i], let par = st.pointee.codecpar else { continue }
            let type = par.pointee.codec_type
            if type == AVMEDIA_TYPE_AUDIO { audioTracks.append(EngineTrack(id: Int32(i), name: Self.trackName(st, audio: true), selected: Int32(i) == bestAudio)) }
            else if type == AVMEDIA_TYPE_SUBTITLE { subTracks.append(EngineTrack(id: Int32(i), name: Self.trackName(st, audio: false), selected: false)) }
            if Int32(i) != videoIndex && Int32(i) != bestAudio && type != AVMEDIA_TYPE_SUBTITLE { st.pointee.discard = AVDISCARD_ALL }
        }
        lock.lock()
        trackList = (audioTracks, subTracks)
        if audioStreamIndex < 0 || !audioTracks.contains(where: { $0.id == audioStreamIndex }) { audioStreamIndex = bestAudio }
        lock.unlock()

        var audio: AudioPipe? = nil
        var subDecoders: [Int32: UnsafeMutablePointer<AVCodecContext>] = [:]
        defer { for c in subDecoders.values { var p: UnsafeMutablePointer<AVCodecContext>? = c; avcodec_free_context(&p) } }

        func openAudio(_ index: Int32) {
            audio?.close(); audio = nil
            guard index >= 0, let st = ctx.pointee.streams[Int(index)] else { return }
            for i in 0..<Int(ctx.pointee.nb_streams) where ctx.pointee.streams[i]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                ctx.pointee.streams[i]?.pointee.discard = Int32(i) == index ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            }
            lock.lock(); let allow = !noPassthrough; lock.unlock()
            audio = AudioPipe(stream: st, allowPassthrough: allow)
            let label = audio?.label ?? ""
            DispatchQueue.main.async { [weak self] in self?.audioLabel = label }
        }
        openAudio(audioStreamIndex)

        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }
        var seekTarget = start
        var openedAudio = audioStreamIndex
        if start > 0.5 { av_seek_frame(ctx, -1, Int64(start * 1_000_000), AVSEEK_FLAG_BACKWARD) }
        startFeeding()

        while running() {
            // Seeks (and audio track changes, which are done as a seek to the same moment).
            lock.lock()
            let seekTo = pendingSeek; pendingSeek = nil
            let wantAudio = audioStreamIndex
            let wantSub = subStreamIndex
            let reopen = reopenAudio; reopenAudio = false
            lock.unlock()
            if wantAudio != openedAudio || reopen { openedAudio = wantAudio; openAudio(wantAudio) }
            if let s = seekTo {
                av_seek_frame(ctx, -1, Int64(max(0, s) * 1_000_000), AVSEEK_FLAG_BACKWARD)
                audio?.flush()
                for (_, c) in subDecoders { avcodec_flush_buffers(c) }
                lock.lock(); videoQ = []; audioQ = []; videoBytes = 0; eof = false; lastQueuedAudio = s; lastQueuedVideo = s; lock.unlock()
                videoFeed.sync { layer.flush() }
                audioFeed.sync { audioRenderer.flush() }
                seekTarget = s
            }
            // Don't read too far ahead of what's playing.
            if bufferedAhead() > 15 || queuedVideoBytes() > 200_000_000 { Thread.sleep(forTimeInterval: 0.02); continue }

            let r = av_read_frame(ctx, pkt)
            if r < 0 {
                if r == AVERR_EOF || ctx.pointee.pb?.pointee.eof_reached == 1 { lock.lock(); eof = true; lock.unlock() }
                else if r != AVERR_EAGAIN { lock.lock(); eof = true; lock.unlock() }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            defer { av_packet_unref(pkt) }
            guard let p = pkt else { continue }
            let si = p.pointee.stream_index
            guard let st = ctx.pointee.streams[Int(si)] else { continue }
            let tb = st.pointee.time_base
            if si == videoIndex {
                if let sb = videoSample(p, tb: tb, format: format, hideBefore: seekTarget) {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    lock.lock()
                    videoQ.append(sb); videoBytes += Int(p.pointee.size)
                    if pts.isFinite { lastQueuedVideo = max(lastQueuedVideo, pts) }
                    let wake = videoWaiting; videoWaiting = false
                    lock.unlock()
                    if wake { requestVideo() }
                }
            } else if si == wantAudio, let a = audio {
                let samples = a.samples(for: p, tb: tb, dropBefore: seekTarget)
                guard !samples.isEmpty else { continue }
                lock.lock()
                audioQ.append(contentsOf: samples)
                if let last = samples.last {
                    let end = (CMSampleBufferGetPresentationTimeStamp(last) + CMSampleBufferGetDuration(last)).seconds
                    if end.isFinite { lastQueuedAudio = max(lastQueuedAudio, end) }
                }
                let wake = audioWaiting; audioWaiting = false
                lock.unlock()
                if wake { requestAudio() }
            } else if st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE, si == wantSub {
                if subDecoders[si] == nil, let c = Self.openDecoder(st) { subDecoders[si] = c }
                if let c = subDecoders[si] { decodeSubtitle(c, packet: p, tb: tb, track: si, videoSize: (Int(vStream.pointee.codecpar.pointee.width), Int(vStream.pointee.codecpar.pointee.height))) }
            }
        }
        audio?.close()
    }

    private func bufferedAhead() -> Double {
        let now = sync.currentTime().seconds
        lock.lock(); defer { lock.unlock() }
        let edge = audioStreamIndex >= 0 ? lastQueuedAudio : lastQueuedVideo
        return edge - (now.isFinite ? now : 0)
    }
    private func queuedVideoBytes() -> Int { lock.lock(); defer { lock.unlock() }; return videoBytes }

    private func fail(_ message: String, fallback: Bool, at time: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clock?.invalidate(); self.clock = nil
            self.onEnd?(fallback ? .fallback(time) : .failed(message))
        }
    }

    // MARK: - Video

    /// Describes the video to Apple's decoder: HEVC / H.264 configuration, Dolby Vision record, HDR colour.
    private func makeVideoFormat(_ st: UnsafeMutablePointer<AVStream>, config: Data) -> CMVideoFormatDescription? {
        guard let par = st.pointee.codecpar?.pointee else { return nil }
        let isHEVC = par.codec_id == AV_CODEC_ID_HEVC
        let isAV1 = par.codec_id == AV_CODEC_ID_AV1
        guard isAV1 ? config.first == 0x81 : config.first == 1 else { return nil }
        guard isHEVC || isAV1 || par.codec_id == AV_CODEC_ID_H264 else { return nil }
        var atoms: [String: Any] = [isAV1 ? "av1C" : isHEVC ? "hvcC" : "avcC": config]
        var codec = isAV1 ? CMVideoCodecType(0x6176_3031) : isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        if isHEVC, let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
           let raw = sd.pointee.data {
            let dv = UnsafeRawPointer(raw).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee
            dvProfile = Int(dv.dv_profile)
            if dv.dv_profile == 7 { return nil }   // dual layer: mpv
            let compat = dv.dv_bl_signal_compatibility_id
            if DeviceCapabilities.dolbyVision {
                var rec = [UInt8](repeating: 0, count: 24)
                rec[0] = dv.dv_version_major; rec[1] = dv.dv_version_minor
                rec[2] = (dv.dv_profile << 1) | (dv.dv_level >> 5)
                rec[3] = ((dv.dv_level & 0x1F) << 3) | (dv.rpu_present_flag << 2) | (dv.el_present_flag << 1) | dv.bl_present_flag
                rec[4] = (compat << 4) | ((dv.dv_md_compression & 0x3) << 2)
                atoms[dv.dv_profile > 7 ? "dvvC" : "dvcC"] = Data(rec)
                codec = kCMVideoCodecType_DolbyVisionHEVC
                hdrLabel = "Dolby Vision \(dv.dv_profile).\(compat == 0 ? "0" : String(compat))"
            } else if compat == 0 {
                return nil   // Profile 5 without a Dolby Vision decoder would show the wrong colours: mpv
            } else {
                hdrLabel = compat == 4 ? "HLG (Dolby Vision base)" : "HDR10 (Dolby Vision base)"
            }
        } else {
            switch par.color_trc {
            case AVCOL_TRC_SMPTE2084: hdrLabel = "HDR10"
            case AVCOL_TRC_ARIB_STD_B67: hdrLabel = "HLG"
            default: hdrLabel = "SDR"
            }
        }

        var ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
        switch par.color_primaries {
        case AVCOL_PRI_BT2020: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_BT709: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        default: break
        }
        switch par.color_trc {
        case AVCOL_TRC_SMPTE2084: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_BT709: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        default: break
        }
        switch par.color_space {
        case AVCOL_SPC_BT2020_NCL: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_BT709: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        default: break
        }
        if par.color_range == AVCOL_RANGE_JPEG { ext[kCMFormatDescriptionExtension_FullRangeVideo] = true }

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: par.width, height: par.height,
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    // MARK: - Making odd files playable

    /// Gets the decoder setup (HEVC 'hvcC' / H.264 'avcC') ready and finds the first keyframe.
    ///
    /// Some files keep their setup data (VPS/SPS/PPS) inside the video itself instead of in the file header —
    /// MP4s tagged 'hev1' or 'avc3', some web downloads and TV recordings. Apple's decoder needs it in the header,
    /// so Huefin reads the first frames, pulls the setup data out, and rebuilds a complete header.
    fileprivate static func prepareVideo(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ st: UnsafeMutablePointer<AVStream>,
                                         _ index: Int32) -> (config: Data, keyframe: Data?)? {
        guard let par = st.pointee.codecpar?.pointee, par.extradata_size > 0, let extra = par.extradata else { return nil }
        var config = Data(bytes: extra, count: Int(par.extradata_size))
        // AV1 (many anime and web files): Apple decodes it in hardware on newer chips (A17 Pro / M3 and later).
        // The file's 'av1C' record goes to the decoder as-is; older devices keep using mpv.
        if par.codec_id == AV_CODEC_ID_AV1 {
            guard config.first == 0x81, VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) else { return nil }
            return (config, firstKeyframe(ctx, index))
        }
        // MKV/MP4 carry a configuration record (first byte 1) and length-prefixed NAL units, which Apple takes as-is.
        guard config.first == 1 else { return nil }
        let isHEVC = par.codec_id == AV_CODEC_ID_HEVC
        guard isHEVC || par.codec_id == AV_CODEC_ID_H264 else { return nil }
        let nalLength = isHEVC ? (config.count > 21 ? Int(config[21] & 3) + 1 : 4) : (config.count > 4 ? Int(config[4] & 3) + 1 : 4)
        let needed: [UInt8] = isHEVC ? [32, 33, 34] : [7, 8]
        let present = Set(Self.parameterSets(in: config, hevc: isHEVC).map(\.type))
        let complete = needed.allSatisfy { present.contains($0) }

        // Read until the first keyframe (and gather any setup data on the way).
        var found: [UInt8: Data] = [:]
        var keyframe: Data?
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }
        var budget = 400
        while budget > 0, keyframe == nil, let p = pkt, av_read_frame(ctx, p) >= 0 {
            defer { av_packet_unref(p) }
            budget -= 1
            guard p.pointee.stream_index == index, let data = p.pointee.data, p.pointee.size > 0 else { continue }
            let bytes = Data(bytes: data, count: Int(p.pointee.size))
            for nal in Self.nalUnits(bytes, lengthSize: nalLength) {
                guard let first = nal.first else { continue }
                let type = isHEVC ? (first >> 1) & 0x3F : first & 0x1F
                if needed.contains(type), found[type] == nil { found[type] = nal }
            }
            if p.pointee.flags & AV_PKT_FLAG_KEY != 0 { keyframe = bytes }
        }
        if !complete {
            guard needed.allSatisfy({ found[$0] != nil }) else { return nil }
            config = isHEVC ? Self.rebuildHVCC(header: config, sets: needed.compactMap { t in found[t].map { (t, $0) } })
                            : Self.rebuildAVCC(header: config, sps: found[7]!, pps: found[8]!)
        }
        return (config, keyframe)
    }

    /// Reads ahead to the first keyframe of the video stream (for the decoder pre-flight test).
    fileprivate static func firstKeyframe(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ index: Int32) -> Data? {
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }
        var budget = 400
        while budget > 0, let p = pkt, av_read_frame(ctx, p) >= 0 {
            defer { av_packet_unref(p) }
            budget -= 1
            guard p.pointee.stream_index == index, let data = p.pointee.data, p.pointee.size > 0,
                  p.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
            return Data(bytes: data, count: Int(p.pointee.size))
        }
        return nil
    }

    /// Splits length-prefixed video data into its NAL units.
    fileprivate static func nalUnits(_ data: Data, lengthSize: Int) -> [Data] {
        var out: [Data] = []
        var i = data.startIndex
        while i + lengthSize <= data.endIndex {
            var len = 0
            for k in 0..<lengthSize { len = (len << 8) | Int(data[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= data.endIndex else { break }
            out.append(data.subdata(in: i..<(i + len)))
            i += len
        }
        return out
    }

    /// The setup NAL units already inside a configuration record.
    fileprivate static func parameterSets(in config: Data, hevc: Bool) -> [(type: UInt8, data: Data)] {
        let b = [UInt8](config)
        var out: [(UInt8, Data)] = []
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        if hevc {
            guard b.count > 22 else { return [] }
            var i = 23
            for _ in 0..<Int(b[22]) {
                guard i + 3 <= b.count else { break }
                let type = b[i] & 0x3F; let count = u16(i + 1); i += 3
                for _ in 0..<count {
                    let len = u16(i); i += 2
                    guard len > 0, i + len <= b.count else { return out }
                    out.append((type, Data(b[i..<(i + len)]))); i += len
                }
            }
        } else {
            guard b.count > 6 else { return [] }
            var i = 6
            for _ in 0..<Int(b[5] & 0x1F) {
                let len = u16(i); i += 2
                guard len > 0, i + len <= b.count else { return out }
                out.append((7, Data(b[i..<(i + len)]))); i += len
            }
            guard i < b.count else { return out }
            let pps = Int(b[i]); i += 1
            for _ in 0..<pps {
                let len = u16(i); i += 2
                guard len > 0, i + len <= b.count else { return out }
                out.append((8, Data(b[i..<(i + len)]))); i += len
            }
        }
        return out
    }

    fileprivate static func rebuildHVCC(header: Data, sets: [(UInt8, Data)]) -> Data {
        var out = Data(header.prefix(22))
        out.append(UInt8(sets.count))
        for (type, nal) in sets {
            out.append(0x80 | type)                       // array_completeness = 1
            out.append(0); out.append(1)                  // one NAL unit
            out.append(UInt8(nal.count >> 8)); out.append(UInt8(nal.count & 0xFF))
            out.append(nal)
        }
        return out
    }

    fileprivate static func rebuildAVCC(header: Data, sps: Data, pps: Data) -> Data {
        var out = Data([1, sps.count > 1 ? sps[sps.startIndex + 1] : header[1], sps.count > 2 ? sps[sps.startIndex + 2] : header[2],
                        sps.count > 3 ? sps[sps.startIndex + 3] : header[3], header.count > 4 ? header[4] | 0xFC : 0xFF, 0xE1])
        out.append(UInt8(sps.count >> 8)); out.append(UInt8(sps.count & 0xFF)); out.append(sps)
        out.append(1)
        out.append(UInt8(pps.count >> 8)); out.append(UInt8(pps.count & 0xFF)); out.append(pps)
        return out
    }

    /// Asks Apple's decoder to decode one keyframe. False means it can't show this video (so mpv should).
    fileprivate static func decodesFirstFrame(_ format: CMVideoFormatDescription, keyframe: Data?) -> Bool {
        guard let keyframe, !keyframe.isEmpty else { return true }   // nothing to test with; the live check still runs
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return false }
        defer { VTDecompressionSessionInvalidate(session) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: keyframe.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: keyframe.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              keyframe.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                         offsetIntoDestination: 0, dataLength: keyframe.count) }) == noErr
        else { return false }
        var sample: CMSampleBuffer?
        var size = keyframe.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return false }
        final class Result: @unchecked Sendable { var ok = false }
        let result = Result()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            result.ok = status == noErr && image != nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        // kVTInvalidSessionErr happens when the app is in the background; don't blame the file for that.
        if status == kVTInvalidSessionErr { return true }
        return status == noErr && result.ok
    }

    private static func cmTime(_ v: Int64, _ tb: AVRational) -> CMTime {
        v == AV_NOPTS ? .invalid : CMTimeMake(value: v * Int64(tb.num), timescale: tb.den)
    }

    private func videoSample(_ p: UnsafeMutablePointer<AVPacket>, tb: AVRational, format: CMVideoFormatDescription, hideBefore: Double) -> CMSampleBuffer? {
        let size = Int(p.pointee.size)
        guard size > 0, let data = p.pointee.data, let block = Self.block(data, size) else { return nil }
        var timing = CMSampleTimingInfo(duration: p.pointee.duration > 0 ? Self.cmTime(p.pointee.duration, tb) : .invalid,
                                        presentationTimeStamp: Self.cmTime(p.pointee.pts, tb),
                                        decodeTimeStamp: Self.cmTime(p.pointee.dts, tb))
        var sz = size
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sz, sampleBufferOut: &sb) == noErr, let sb
        else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            if p.pointee.flags & AV_PKT_FLAG_KEY == 0 {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            let pts = timing.presentationTimeStamp.seconds
            if pts.isFinite && pts < hideBefore - 0.001 {   // after a seek: decode from the keyframe, show from the target
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }

    fileprivate static func block(_ data: UnsafeMutablePointer<UInt8>, _ size: Int) -> CMBlockBuffer? {
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr,
              let bb, CMBlockBufferReplaceDataBytes(with: data, blockBuffer: bb, offsetIntoDestination: 0, dataLength: size) == noErr
        else { return nil }
        return bb
    }

    // MARK: - Feeding Apple's renderers

    private func startFeeding() { requestVideo(); requestAudio() }

    private func requestVideo() {
        layer.requestMediaDataWhenReady(on: videoFeed) { [weak self] in
            guard let self else { return }
            while self.layer.isReadyForMoreMediaData {
                self.lock.lock()
                guard !self.videoQ.isEmpty else {
                    // Stop before saying we're waiting, so new data can never arrive in between and be missed.
                    self.layer.stopRequestingMediaData()
                    self.videoWaiting = true
                    self.lock.unlock()
                    return
                }
                let sb = self.videoQ.removeFirst()
                self.videoBytes -= CMSampleBufferGetTotalSampleSize(sb)
                self.lock.unlock()
                self.layer.enqueue(sb)
            }
        }
    }

    private func requestAudio() {
        audioRenderer.requestMediaDataWhenReady(on: audioFeed) { [weak self] in
            guard let self else { return }
            while self.audioRenderer.isReadyForMoreMediaData {
                self.lock.lock()
                guard !self.audioQ.isEmpty else {
                    // Stop before saying we're waiting, so new data can never arrive in between and be missed.
                    self.audioRenderer.stopRequestingMediaData()
                    self.audioWaiting = true
                    self.lock.unlock()
                    return
                }
                let sb = self.audioQ.removeFirst()
                self.lock.unlock()
                self.audioRenderer.enqueue(sb)
            }
        }
    }

    // MARK: - The clock: starting, buffering, the end, and recovering from problems

    private func startClock() {
        clock?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.clockTick() }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func clockTick() {
        lock.lock(); let atEnd = eof; let lastMedia = max(lastQueuedVideo, audioStreamIndex >= 0 ? lastQueuedAudio : 0); lock.unlock()
        let ahead = bufferedAhead()
        // Safety net: if a feeder is idle but data is waiting, wake it.
        lock.lock()
        let kickVideo = videoWaiting && !videoQ.isEmpty, kickAudio = audioWaiting && !audioQ.isEmpty
        if kickVideo { videoWaiting = false }
        if kickAudio { audioWaiting = false }
        lock.unlock()
        if kickVideo { requestVideo() }
        if kickAudio { requestAudio() }

        // Apple's decoder refused the video (e.g. a Dolby Vision file this device can't decode): mpv takes over.
        if layer.status == .failed {
            let code = (layer.error as NSError?)?.code ?? 0
            if code == -11847 { return }   // interrupted by the app going to the background; handled on return
            let t = time
            clock?.invalidate(); clock = nil
            onEnd?(.fallback(t))
            return
        }
        // Dolby audio passthrough rejected: decode it here instead.
        if audioRenderer.status == .failed && !passthroughFailed {
            passthroughFailed = true
            lock.lock(); noPassthrough = true; reopenAudio = true; lock.unlock()
            seek(to: time)
            return
        }

        switch phase {
        case .starting(let at):
            if ahead >= 1.5 || atEnd {
                phase = .playing
                sync.setRate(userPaused ? 0 : rate, time: CMTime(seconds: at, preferredTimescale: 90_000))
                if !startedOnce { startedOnce = true }
                onPlaybackRestart?()
            }
        case .playing:
            if !atEnd && ahead < 0.25 && !userPaused {
                phase = .buffering
                sync.rate = 0
            } else if atEnd && time >= lastMedia - 0.15 {
                phase = .ended
                sync.rate = 0
                onEnd?(.finished)
            }
        case .buffering:
            if ahead >= 2.5 || atEnd {
                phase = .playing
                if !userPaused { sync.rate = rate }
            }
        case .idle, .ended:
            break
        }
    }

    @objc private func foreground() {
        if layer.requiresFlushToResumeDecoding || layer.status == .failed {
            seek(to: time)
        }
    }

    // MARK: - Controls

    func play() {
        userPaused = false
        if case .playing = phase { sync.rate = rate }
    }
    func pause() {
        userPaused = true
        sync.rate = 0
    }
    func seek(to seconds: Double) {
        let s = max(0, durationSeconds > 0 ? min(seconds, durationSeconds - 0.5) : seconds)
        lock.lock(); pendingSeek = s; eof = false; lock.unlock()
        sync.setRate(0, time: CMTime(seconds: s, preferredTimescale: 90_000))
        phase = .starting(s)
    }

    var time: Double { let t = sync.currentTime().seconds; return t.isFinite ? max(0, t) : 0 }
    var duration: Double { durationSeconds }
    var isPaused: Bool { userPaused }
    var isPlaying: Bool { if case .playing = phase { return !userPaused } else { return false } }
    var speed: Double {
        get { Double(rate) }
        set { rate = Float(newValue); if isPlaying { sync.rate = rate } }
    }
    var volume: Double {
        get { Double(audioRenderer.volume) * 100 }
        set { audioRenderer.volume = Float(min(100, max(0, newValue)) / 100) }
    }

    func tracks(_ type: String) -> [EngineTrack] {
        lock.lock(); defer { lock.unlock() }
        if type == "audio" {
            return trackList.audio.map { EngineTrack(id: $0.id, name: $0.name, selected: $0.id == audioStreamIndex) }
        }
        let all = trackList.subs + externalSubs.map { EngineTrack(id: $0.id, name: $0.name, selected: false) }
        return all.map { EngineTrack(id: $0.id, name: $0.name, selected: $0.id == subStreamIndex) }
    }
    func selectAudio(_ id: Int32) {
        lock.lock(); let changed = id != audioStreamIndex; audioStreamIndex = id; lock.unlock()
        if changed { seek(to: time) }   // reopens the audio at the same moment
    }
    func selectSubtitle(_ id: Int32) {
        lock.lock(); let changed = id != subStreamIndex; subStreamIndex = id; let haveCues = cues[id]?.isEmpty == false; lock.unlock()
        // Embedded subtitles are read as the file plays; jump back a moment so the current line appears now.
        if changed && id >= 0 && id < 1000 && !haveCues { seek(to: time) }
    }

    var overlaySubtitle: EngineSubtitle? {
        let t = time
        lock.lock(); defer { lock.unlock() }
        guard subStreamIndex >= 0, let list = cues[subStreamIndex] else { return nil }
        return list.last(where: { $0.start <= t && t < $0.end })?.content
    }

    var pictureDescription: String {
        let out: String
        #if os(tvOS)
        out = hdrLabel.hasPrefix("Dolby Vision") ? "Dolby Vision mode" : hdrLabel == "SDR" ? "SDR" : "HDR mode"
        #else
        out = hdrLabel == "SDR" ? "SDR" : "HDR screen"
        #endif
        return "\(hdrLabel) → \(out) · Apple decoder" + (audioLabel.isEmpty ? "" : " · \(audioLabel)")
    }

    // MARK: - Apple TV display mode

    #if os(tvOS)
    var displaySignature: String { hdrLabel + "@" + String(frameRate) }

    /// With the real format description, the TV switches into Dolby Vision (or HDR10/HLG) and the film's frame rate.
    @MainActor func matchDisplay(in window: UIWindow?) -> Bool {
        guard let manager = window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled, let videoFormat else { return false }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: videoFormat)
        return true
    }
    #endif

    // MARK: - Subtitles

    func addSubtitle(_ url: URL, title: String, lang: String?) {
        if currentURL == nil { pendingExternal.append((url, title, lang)); return }
        loadExternalSubtitle(url, title: title, lang: lang)
    }

    /// Subtitle files next to the video on the server: read whole (they're small) and decoded up front.
    private func loadExternalSubtitle(_ url: URL, title: String, lang: String?) {
        lock.lock(); let id = Int32(1000 + externalSubs.count); externalSubs.append((id, title)); lock.unlock()
        subQueue.async { [weak self] in
            var fmt: UnsafeMutablePointer<AVFormatContext>? = nil
            guard avformat_open_input(&fmt, url.absoluteString, nil, nil) >= 0, let ctx = fmt else { return }
            defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }
            avformat_find_stream_info(ctx, nil)
            guard ctx.pointee.nb_streams > 0, let st = ctx.pointee.streams[0], let dec = Self.openDecoder(st) else { return }
            defer { var p: UnsafeMutablePointer<AVCodecContext>? = dec; avcodec_free_context(&p) }
            let pkt = av_packet_alloc()
            defer { var p = pkt; av_packet_free(&p) }
            while av_read_frame(ctx, pkt) >= 0 {
                if let p = pkt { self?.decodeSubtitle(dec, packet: p, tb: st.pointee.time_base, track: id, videoSize: (0, 0)) }
                av_packet_unref(pkt)
            }
        }
    }

    fileprivate static func openDecoder(_ st: UnsafeMutablePointer<AVStream>) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let par = st.pointee.codecpar, let codec = avcodec_find_decoder(par.pointee.codec_id),
              let c = avcodec_alloc_context3(codec) else { return nil }
        var ctx: UnsafeMutablePointer<AVCodecContext>? = c
        guard avcodec_parameters_to_context(c, par) >= 0 else { avcodec_free_context(&ctx); return nil }
        c.pointee.pkt_timebase = st.pointee.time_base
        guard avcodec_open2(c, codec, nil) >= 0 else { avcodec_free_context(&ctx); return nil }
        return c
    }

    private func decodeSubtitle(_ dec: UnsafeMutablePointer<AVCodecContext>, packet p: UnsafeMutablePointer<AVPacket>,
                                tb: AVRational, track: Int32, videoSize: (Int, Int)) {
        var sub = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(dec, &sub, &got, p) >= 0, got != 0 else { return }
        defer { avsubtitle_free(&sub) }
        let base = p.pointee.pts != AV_NOPTS ? Self.cmTime(p.pointee.pts, tb).seconds : (sub.pts != AV_NOPTS ? Double(sub.pts) / 1_000_000 : 0)
        let start = base + Double(sub.start_display_time) / 1000
        var end: Double
        if sub.end_display_time > sub.start_display_time { end = base + Double(sub.end_display_time) / 1000 }
        else if p.pointee.duration > 0 { end = base + Self.cmTime(p.pointee.duration, tb).seconds }
        else { end = .infinity }   // picture subtitles: shown until the next one clears it

        var content: EngineSubtitle?
        if sub.num_rects > 0, let rects = sub.rects {
            var lines: [String] = []
            var image: (CGImage, CGRect)?
            for i in 0..<Int(sub.num_rects) {
                guard let r = rects[i]?.pointee else { continue }
                if r.type == SUBTITLE_BITMAP {
                    let w = videoSize.0 > 0 ? videoSize.0 : Int(dec.pointee.width), h = videoSize.1 > 0 ? videoSize.1 : Int(dec.pointee.height)
                    if image == nil, let img = Self.bitmap(r), w > 0, h > 0 {
                        image = (img, CGRect(x: Double(r.x) / Double(w), y: Double(r.y) / Double(h),
                                             width: Double(r.w) / Double(w), height: Double(r.h) / Double(h)))
                    }
                } else if let ass = r.ass {
                    lines.append(Self.plainText(fromASS: String(cString: ass)))
                } else if let text = r.text {
                    lines.append(String(cString: text))
                }
            }
            if let image { content = .image(image.0, image.1) }
            else if !lines.isEmpty { content = .text(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        lock.lock()
        var list = cues[track] ?? []
        // A new subtitle (or an empty "clear") ends a picture subtitle that had no set end.
        if let last = list.indices.last, list[last].end == .infinity, list[last].start <= start { list[last].end = start }
        var empty = content == nil
        if case .text(let s)? = content, s.isEmpty { empty = true }
        if !empty, let content {
            if let i = list.firstIndex(where: { abs($0.start - start) < 0.001 }) { list[i] = Cue(start: start, end: end, content: content) }
            else { list.append(Cue(start: start, end: end, content: content)); list.sort { $0.start < $1.start } }
        }
        if list.count > 4000 { list.removeFirst(list.count - 4000) }
        cues[track] = list
        lock.unlock()
    }

    /// "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text" → the text, without styling tags.
    private static func plainText(fromASS line: String) -> String {
        let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        var text = parts.count == 9 ? String(parts[8]) : line
        while let open = text.range(of: "{"), let close = text.range(of: "}", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
    }

    /// A palette subtitle picture (PGS / DVD) as an RGBA image.
    private static func bitmap(_ r: AVSubtitleRect) -> CGImage? {
        guard r.w > 0, r.h > 0, let idx = r.data.0, let pal = r.data.1 else { return nil }
        let w = Int(r.w), h = Int(r.h), stride = Int(r.linesize.0)
        let palette = UnsafeRawPointer(pal).assumingMemoryBound(to: UInt32.self)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let argb = palette[Int(idx[y * stride + x])]
                let a = UInt8((argb >> 24) & 0xFF)
                let o = (y * w + x) * 4
                // Premultiplied RGBA.
                rgba[o] = UInt8((UInt32((argb >> 16) & 0xFF) * UInt32(a)) / 255)
                rgba[o + 1] = UInt8((UInt32((argb >> 8) & 0xFF) * UInt32(a)) / 255)
                rgba[o + 2] = UInt8((UInt32(argb & 0xFF) * UInt32(a)) / 255)
                rgba[o + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func trackName(_ st: UnsafeMutablePointer<AVStream>, audio: Bool) -> String {
        func tag(_ k: String) -> String? {
            guard let e = av_dict_get(st.pointee.metadata, k, nil, 0), let v = e.pointee.value else { return nil }
            let s = String(cString: v); return s.isEmpty ? nil : s
        }
        var parts: [String] = []
        if let t = tag("title") { parts.append(t) }
        if let l = tag("language"), l != "und" { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
        if let par = st.pointee.codecpar, let name = avcodec_get_name(par.pointee.codec_id) {
            parts.append(String(cString: name).uppercased().replacingOccurrences(of: "HDMV_PGS_SUBTITLE", with: "PGS")
                .replacingOccurrences(of: "SUBRIP", with: "SRT").replacingOccurrences(of: "DCA", with: "DTS"))
            if audio {
                let ch = Int(par.pointee.ch_layout.nb_channels)
                parts.append([1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][ch] ?? "\(ch)ch")
            }
        }
        if st.pointee.disposition & AV_DISPOSITION_FORCED != 0 { parts.append("Forced") }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }
}

// MARK: - iPhone / iPad Picture in Picture

#if os(iOS)
extension NativeCore: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Picture in Picture straight from the engine's own layer (no hand-off to another player).
    func makePiPController() -> AVPictureInPictureController? {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        return c
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { playing ? self.play() : self.pause() }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: max(durationSeconds, 1), preferredTimescale: 600))
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { userPaused }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        DispatchQueue.main.async { self.seek(to: self.time + skipInterval.seconds); completion() }
    }
}
#endif

// MARK: - Audio

/// One audio track on its way to Apple's audio renderer.
/// Dolby Digital / Dolby Digital Plus (incl. Atmos) go untouched; everything else is decoded to float PCM.
private final class AudioPipe {
    let label: String
    private var passthrough: CMAudioFormatDescription?
    private var dec: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?
    private var pcmFormat: CMAudioFormatDescription?
    private var pcmChannels: Int32 = 0
    private var pcmRate: Int32 = 0
    private let frame = av_frame_alloc()

    init?(stream st: UnsafeMutablePointer<AVStream>, allowPassthrough: Bool) {
        guard let par = st.pointee.codecpar?.pointee else { return nil }
        let id = par.codec_id
        let ch = par.ch_layout.nb_channels
        if allowPassthrough && (id == AV_CODEC_ID_EAC3 || id == AV_CODEC_ID_AC3) && par.sample_rate > 0 {
            var asbd = AudioStreamBasicDescription(mSampleRate: Float64(par.sample_rate),
                                                   mFormatID: id == AV_CODEC_ID_EAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
                                                   mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
                                                   mChannelsPerFrame: UInt32(max(ch, 2)), mBitsPerChannel: 0, mReserved: 0)
            var fd: CMAudioFormatDescription?
            if CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                              magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr {
                passthrough = fd
            }
        }
        if passthrough == nil {
            dec = NativeCore.openDecoder(st)
            if dec == nil { return nil }
        }
        let name = String(cString: avcodec_get_name(id)).uppercased().replacingOccurrences(of: "DCA", with: "DTS")
        label = passthrough != nil ? "\(name) untouched" : "\(name) → PCM \(ch == 8 ? "7.1" : ch == 6 ? "5.1" : "\(ch)ch")"
    }

    func flush() { if let dec { avcodec_flush_buffers(dec) } }

    func close() {
        var d = dec; avcodec_free_context(&d); dec = nil
        if swr != nil { swr_free(&swr) }
        var f = frame; av_frame_free(&f)
    }

    func samples(for p: UnsafeMutablePointer<AVPacket>, tb: AVRational, dropBefore: Double) -> [CMSampleBuffer] {
        if let fd = passthrough {
            let pts = p.pointee.pts != AV_NOPTS ? CMTimeMake(value: p.pointee.pts * Int64(tb.num), timescale: tb.den) : .invalid
            let dur = Double(p.pointee.duration) * Double(tb.num) / Double(tb.den)
            if pts.isValid && pts.seconds + dur < dropBefore { return [] }
            guard let data = p.pointee.data, let bb = NativeCore.block(data, Int(p.pointee.size)) else { return [] }
            var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.pointee.size))
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                                                 sampleCount: 1, presentationTimeStamp: pts, packetDescriptions: &desc,
                                                                 sampleBufferOut: &sb)
            return sb.map { [$0] } ?? []
        }
        guard let dec, let frame, avcodec_send_packet(dec, p) >= 0 else { return [] }
        var out: [CMSampleBuffer] = []
        while avcodec_receive_frame(dec, frame) >= 0 {
            defer { av_frame_unref(frame) }
            let n = frame.pointee.nb_samples
            guard n > 0 else { continue }
            let ts = frame.pointee.best_effort_timestamp != AV_NOPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
            let start = ts != AV_NOPTS ? Double(ts) * Double(tb.num) / Double(tb.den) : .nan
            let rate = frame.pointee.sample_rate
            if start.isFinite && start + Double(n) / Double(rate) < dropBefore { continue }
            guard prepare(frame.pointee), let swr, let fd = pcmFormat else { continue }
            let ch = Int(pcmChannels)
            let bytes = Int(n) * ch * 4
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
            defer { buf.deallocate() }
            var outPtrs: [UnsafeMutablePointer<UInt8>?] = [buf]
            let inPtrs = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            let got = outPtrs.withUnsafeMutableBufferPointer { o in swr_convert(swr, o.baseAddress, n, inPtrs, n) }
            guard got > 0, let bb = NativeCore.block(buf, Int(got) * ch * 4) else { continue }
            let pts = start.isFinite ? CMTime(seconds: start, preferredTimescale: rate) : .invalid
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                                                 sampleCount: CMItemCount(got), presentationTimeStamp: pts,
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            if let sb { out.append(sb) }
        }
        return out
    }

    /// Sets up the converter and the PCM description (with the right speaker positions) for this frame's layout.
    private func prepare(_ f: AVFrame) -> Bool {
        let ch = f.ch_layout.nb_channels
        if swr != nil && ch == pcmChannels && f.sample_rate == pcmRate { return true }
        if swr != nil { swr_free(&swr) }
        var inLayout = f.ch_layout
        var outLayout = AVChannelLayout()
        av_channel_layout_copy(&outLayout, &inLayout)
        defer { av_channel_layout_uninit(&outLayout) }
        let inFormat = AVSampleFormat(rawValue: f.format)
        guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, f.sample_rate, &inLayout, inFormat, f.sample_rate, 0, nil) >= 0,
              swr_init(swr) >= 0 else { return false }
        pcmChannels = ch; pcmRate = f.sample_rate

        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(f.sample_rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch),
                                               mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
        // Speaker positions, one per channel in FFmpeg's order.
        let n = Int(max(ch, 1))
        let size = MemoryLayout<AudioChannelLayout>.size + (n - 1) * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        var layoutSize = MemoryLayout<AudioChannelLayout>.size
        if ch == 1 { layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Mono }
        else if ch == 2 { layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo }
        else {
            layoutSize = size
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mNumberChannelDescriptions = UInt32(n)
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
            let descs = (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            var lay = f.ch_layout
            var chans: [Int32] = []
            for i in 0..<n { chans.append(av_channel_layout_channel_from_index(&lay, UInt32(i)).rawValue) }
            let hasSide = chans.contains(9) || chans.contains(10)
            for (i, c) in chans.enumerated() {
                let label: UInt32
                switch c {
                case 0: label = 1; case 1: label = 2; case 2: label = 3; case 3: label = 4          // L R C LFE
                case 4: label = hasSide ? 33 : 5; case 5: label = hasSide ? 34 : 6                  // back L/R
                case 9: label = 5; case 10: label = 6                                               // side L/R
                case 6: label = 7; case 7: label = 8; case 8: label = 9                             // Lc Rc Cs
                case 11: label = 12; case 12: label = 13; case 13: label = 14; case 14: label = 15
                case 15: label = 16; case 16: label = 17; case 17: label = 18
                default: label = 0
                }
                descs[i] = AudioChannelDescription(mChannelLabel: label, mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
        }
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: layoutSize, layout: layout,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr
        else { return false }
        pcmFormat = fd
        return true
    }
}

// MARK: - Self test (used by the engine test suite in CI)

/// What the native engine makes of one file, without playing it: can Apple's decoder show the picture,
/// how long that took, does jumping to the middle work, and can every audio and subtitle track be read.
struct EngineSelfTest: CustomStringConvertible {
    var nativeVideo = false
    var fallbackReason: String?
    var openSeconds = 0.0
    var firstFrameSeconds = 0.0
    var seekOK = false
    var audioTracks = 0, audioDecodable = 0
    var subtitleTracks = 0, subtitleDecodable = 0
    /// Gap between where the first audio and the first video start, in seconds (big gaps drift out of sync).
    var startGap: Double?
    var description: String {
        "native=\(nativeVideo) fallback=\(fallbackReason ?? "-") open=\(String(format: "%.2f", openSeconds))s " +
        "firstFrame=\(String(format: "%.2f", firstFrameSeconds))s seek=\(seekOK) audio=\(audioDecodable)/\(audioTracks) " +
        "subs=\(subtitleDecodable)/\(subtitleTracks) startGap=\(startGap.map { String(format: "%.3f", $0) } ?? "-")"
    }
}

extension NativeCore {
    static func selfTest(path: String) -> EngineSelfTest {
        var r = EngineSelfTest()
        let t0 = CACurrentMediaTime()
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, path, nil, nil) >= 0, let ctx = fmt else { r.fallbackReason = "couldn't open"; return r }
        defer { var f: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&f) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { r.fallbackReason = "couldn't read streams"; return r }
        r.openSeconds = CACurrentMediaTime() - t0

        var videoStart: Double?, audioStart: Double?
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i], let par = st.pointee.codecpar else { continue }
            let tb = st.pointee.time_base
            let start = st.pointee.start_time == Int64.min ? nil : Double(st.pointee.start_time) * Double(tb.num) / Double(max(1, tb.den))
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_AUDIO:
                r.audioTracks += 1
                if audioStart == nil { audioStart = start }
                if let dec = avcodec_find_decoder(par.pointee.codec_id) {
                    var cc = avcodec_alloc_context3(dec)
                    if let c = cc, avcodec_parameters_to_context(c, par) >= 0, avcodec_open2(c, dec, nil) >= 0 { r.audioDecodable += 1 }
                    avcodec_free_context(&cc)
                }
            case AVMEDIA_TYPE_SUBTITLE:
                r.subtitleTracks += 1
                if avcodec_find_decoder(par.pointee.codec_id) != nil { r.subtitleDecodable += 1 }
            case AVMEDIA_TYPE_VIDEO:
                if videoStart == nil, st.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 { videoStart = start }
            default: break
            }
        }
        if let v = videoStart, let a = audioStart { r.startGap = abs(v - a) }

        let vi = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard vi >= 0, let vs = ctx.pointee.streams[Int(vi)] else { r.fallbackReason = "no video"; return r }
        guard let prepared = prepareVideo(ctx, vs, vi) else { r.fallbackReason = "mpv: no usable decoder setup"; return r }
        let core = NativeCore()
        guard let format = core.makeVideoFormat(vs, config: prepared.config) else { r.fallbackReason = "mpv: codec or profile"; return r }
        guard decodesFirstFrame(format, keyframe: prepared.keyframe) else { r.fallbackReason = "mpv: Apple's decoder refused the first frame"; return r }
        r.nativeVideo = true
        r.firstFrameSeconds = CACurrentMediaTime() - t0

        // Jump to the middle and decode the keyframe found there.
        let duration = ctx.pointee.duration
        if duration > 0, av_seek_frame(ctx, -1, duration / 2, AVSEEK_FLAG_BACKWARD) >= 0 {
            let pkt = av_packet_alloc()
            defer { var p = pkt; av_packet_free(&p) }
            var budget = 2000
            while budget > 0, let p = pkt, av_read_frame(ctx, p) >= 0 {
                defer { av_packet_unref(p) }
                budget -= 1
                guard p.pointee.stream_index == vi, p.pointee.flags & AV_PKT_FLAG_KEY != 0, let d = p.pointee.data else { continue }
                r.seekOK = decodesFirstFrame(format, keyframe: Data(bytes: d, count: Int(p.pointee.size)))
                break
            }
        } else {
            r.seekOK = duration <= 0
        }
        return r
    }
}
#endif
