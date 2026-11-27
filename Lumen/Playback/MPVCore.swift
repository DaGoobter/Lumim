import UIKit
import AVFoundation
import CoreMedia
#if canImport(Libmpv)
import Libmpv

/// The layer mpv draws into (through MoltenVK and Metal).
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK can briefly set a 1×1 drawable to finish presenting; ignoring it avoids a flicker and a stuck 1×1 picture.
    // https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
}

/// A view whose own layer is mpv's canvas, so it always fills exactly the view.
final class MPVVideoView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsScale = UIScreen.main.nativeScale
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let s = window?.screen { metalLayer.contentsScale = s.nativeScale }
    }
}

/// The Huefin Engine core on iPhone, iPad and Apple TV: mpv with libplacebo and FFmpeg.
///
/// - Hardware decoding through VideoToolbox.
/// - HDR10, HDR10+ and HLG go out as real HDR on HDR screens (Extended Dynamic Range on iPhone/iPad, HDR display
///   mode on Apple TV), and are tone-mapped properly on screens that can't show HDR.
/// - Dolby Vision is reshaped by libplacebo from its own metadata, so Profile 5 shows its true colours and
///   Profiles 7 and 8 get the Dolby Vision grade on top of their HDR10 picture.
/// - Any audio (TrueHD, DTS-HD, FLAC…) is decoded to multichannel sound for the TV, receiver or headphones.
final class MPVCore: EngineCore {
    let view = MPVVideoView()
    var videoView: UIView { view }
    var engineName: String { "mpv" }
    var overlaySubtitle: EngineSubtitle? { nil }
    /// Called on the main thread.
    var onFileLoaded: (() -> Void)?
    var onPlaybackRestart: (() -> Void)?
    var onEnd: ((EngineEnd) -> Void)?
    var onVideoReconfig: (() -> Void)?

    private let lock = NSLock()
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "app.huefin.mpv", qos: .userInitiated)
    private var observersSet = false

    /// Whether this screen can show HDR. mpv is told up front, because it can't switch later.
    static var screenSupportsHDR: Bool {
        #if os(tvOS)
        return AVPlayer.eligibleForHDRPlayback
        #else
        if #available(iOS 16.0, *) { return UIScreen.main.potentialEDRHeadroom > 1.0 }
        return false
        #endif
    }

    init() {
        guard let h = mpv_create() else { return }
        mpv = h
        #if DEBUG
        mpv_request_log_messages(h, "warn")
        #else
        mpv_request_log_messages(h, "no")
        #endif
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(view.layer).toOpaque()))
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid)
        let hdr = Self.screenSupportsHDR
        let options: [(String, String)] = [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("hwdec-codecs", "all"),
            // HDR: hand HDR straight to an HDR screen; otherwise libplacebo tone-maps it.
            ("target-colorspace-hint", hdr ? "yes" : "no"),
            ("tone-mapping", "auto"), ("hdr-compute-peak", "auto"), ("gamut-mapping-mode", "auto"),
            ("video-rotate", "no"), ("keepaspect", "yes"),
            ("audio-channels", "auto"), ("volume-max", "200"),
            ("cache", "yes"), ("demuxer-max-bytes", "200MiB"), ("demuxer-max-back-bytes", "50MiB"), ("demuxer-readahead-secs", "30"),
            ("network-timeout", "30"), ("user-agent", "Huefin"),
            ("keep-open", "no"), ("idle", "yes"), ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
            ("osd-level", "0"), ("sub-ass-override", "no"), ("sub-scale-with-window", "yes"), ("sub-use-margins", "yes"),
            ("ytdl", "no"), ("save-position-on-quit", "no"), ("subs-fallback", "yes"),
        ]
        for (k, v) in options { mpv_set_option_string(h, k, v) }
        // Let mpv use every speaker the TV, receiver or headphones offer (5.1 / 7.1 and spatial audio).
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        #else
        try? session.setCategory(.playback, mode: .moviePlayback)
        #endif
        if #available(iOS 15.0, tvOS 15.0, *) { try? session.setSupportsMultichannelContent(true) }
        try? session.setActive(true)
        try? session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
        guard mpv_initialize(h) >= 0 else { mpv_terminate_destroy(h); mpv = nil; return }
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit { destroy() }

    var isReady: Bool { handle() != nil }

    private func handle() -> OpaquePointer? { lock.lock(); defer { lock.unlock() }; return mpv }

    /// Shuts mpv down off the main thread. Safe to call more than once.
    func destroy() {
        lock.lock(); let h = mpv; mpv = nil; lock.unlock()
        guard let h else { return }
        NotificationCenter.default.removeObserver(self)
        queue.async {
            mpv_set_wakeup_callback(h, nil, nil)
            mpv_terminate_destroy(h)
        }
    }

    // Without a visible layer Metal would stall; drop the picture in the background and bring it back after.
    @objc private func background() { setString("vid", "no") }
    @objc private func foreground() { setString("vid", "auto") }

    // MARK: Commands and properties

    func command(_ args: [String]) {
        guard let h = handle() else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } } }
        mpv_command(h, &cargs)
    }
    func setString(_ name: String, _ value: String) {
        guard let h = handle() else { return }
        mpv_set_property_string(h, name, value)
    }
    func string(_ name: String) -> String? {
        guard let h = handle(), let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    func double(_ name: String) -> Double? {
        guard let h = handle() else { return nil }
        var d = 0.0
        return mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &d) >= 0 ? d : nil
    }
    func int(_ name: String) -> Int64? {
        guard let h = handle() else { return nil }
        var i: Int64 = 0
        return mpv_get_property(h, name, MPV_FORMAT_INT64, &i) >= 0 ? i : nil
    }
    func flag(_ name: String) -> Bool {
        guard let h = handle() else { return false }
        var f: Int32 = 0
        return mpv_get_property(h, name, MPV_FORMAT_FLAG, &f) >= 0 && f != 0
    }
    func setFlag(_ name: String, _ on: Bool) {
        guard let h = handle() else { return }
        var f: Int32 = on ? 1 : 0
        mpv_set_property(h, name, MPV_FORMAT_FLAG, &f)
    }
    func setDouble(_ name: String, _ v: Double) {
        guard let h = handle() else { return }
        var d = v
        mpv_set_property(h, name, MPV_FORMAT_DOUBLE, &d)
    }

    // MARK: Playback

    func load(_ url: URL, start: Double) {
        pendingSubs = []
        fileLoaded = false
        setString("start", start > 0 ? String(format: "%.3f", start) : "none")
        command(["loadfile", url.absoluteString, "replace"])
        setFlag("pause", false)
    }
    private var pendingSubs: [(url: URL, title: String, lang: String?)] = []
    private var fileLoaded = false

    /// A subtitle file kept next to the video on the server. Added as soon as the video has opened.
    func addSubtitle(_ url: URL, title: String, lang: String?) {
        if fileLoaded { command(["sub-add", url.absoluteString, "auto", title, lang ?? ""]) }
        else { pendingSubs.append((url, title, lang)) }
    }

    func play() { setFlag("pause", false) }
    func pause() { setFlag("pause", true) }
    func seek(to seconds: Double) { command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"]) }
    func stop() { command(["stop"]) }

    var time: Double { double("time-pos") ?? 0 }
    var duration: Double { double("duration") ?? 0 }
    var isPaused: Bool { flag("pause") }
    var isBuffering: Bool { flag("paused-for-cache") || flag("seeking") }
    var isIdle: Bool { flag("idle-active") }
    var isPlaying: Bool { !isPaused && !isIdle && !flag("core-idle") }
    var speed: Double { get { double("speed") ?? 1 } set { setDouble("speed", newValue) } }
    var subtitleDelay: Double { get { double("sub-delay") ?? 0 } set { setDouble("sub-delay", newValue) } }
    var audioDelay: Double { get { double("audio-delay") ?? 0 } set { setDouble("audio-delay", newValue) } }
    private var night = false
    var nightMode: Bool {
        get { night }
        set {
            night = newValue
            // Same idea as the native engine: stereo with full-level dialogue, then a gentle compressor and a ceiling.
            // (mpv's own downmix handles any layout; a fixed channel map would break on stereo files.)
            setString("audio-channels", newValue ? "stereo" : "auto")
            setString("af", newValue ? "lavfi=[acompressor=threshold=-26dB:ratio=3:attack=10:release=250:makeup=8],lavfi=[alimiter=limit=0.89]" : "")
        }
    }
    var videoAspect: Double {
        guard let w = double("video-params/dw"), let h = double("video-params/dh"), w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }
    var volume: Double { get { double("volume") ?? 100 } set { setDouble("volume", newValue) } }

    /// Audio ("audio") or subtitle ("sub") tracks, with readable names.
    func tracks(_ type: String) -> [EngineTrack] {
        let n = Int(int("track-list/count") ?? 0)
        return (0..<n).compactMap { i in
            guard string("track-list/\(i)/type") == type, let id = int("track-list/\(i)/id") else { return nil }
            var parts: [String] = []
            if let t = string("track-list/\(i)/title"), !t.isEmpty { parts.append(t) }
            if let l = string("track-list/\(i)/lang"), !l.isEmpty {
                parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l)
            }
            if let c = string("track-list/\(i)/codec") {
                parts.append(c.uppercased().replacingOccurrences(of: "PGSSUB", with: "PGS").replacingOccurrences(of: "SUBRIP", with: "SRT"))
            }
            if type == "audio", let ch = int("track-list/\(i)/demux-channel-count"), ch > 0 {
                parts.append([1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][ch] ?? "\(ch)ch")
            }
            if flag("track-list/\(i)/forced") { parts.append("Forced") }
            var seen = Set<String>()
            let name = parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
            return EngineTrack(id: Int32(id), name: name.isEmpty ? (type == "audio" ? "Track \(id)" : "Subtitles \(id)") : name,
                         selected: flag("track-list/\(i)/selected"))
        }
    }
    func selectAudio(_ id: Int32) { setString("aid", "\(id)") }
    func selectSubtitle(_ id: Int32) { setString("sid", id < 0 ? "no" : "\(id)") }
    var audioId: Int32 { Int32(int("aid") ?? -1) }
    var subtitleId: Int32 { Int32(int("sid") ?? -1) }

    /// What's on screen, for the info panel: "Dolby Vision → HDR10 (PQ)", "HDR10 → SDR (tone mapped)"…
    var pictureDescription: String {
        let gamma = string("video-params/gamma") ?? ""
        let out = string("video-target-params/gamma") ?? ""
        let dv = (string("video-dec-params/dovi-profile") ?? string("video-params/dovi-profile")).map { "Dolby Vision P\($0)" }
        let src = dv ?? ["pq": "HDR10", "hlg": "HLG"][gamma] ?? "SDR"
        let dst = ["pq": "HDR (PQ)", "hlg": "HDR (HLG)"][out] ?? "SDR"
        let hw = string("hwdec-current").map { $0 == "no" || $0.isEmpty ? "software decode" : "hardware decode" } ?? ""
        return "\(src) → \(dst)\(src != "SDR" && dst == "SDR" ? ", tone mapped" : "") · \(hw)"
    }

    // MARK: Events

    fileprivate func drainEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let h = self.handle() {
                guard let ev = mpv_wait_event(h, 0)?.pointee, ev.event_id != MPV_EVENT_NONE else { break }
                switch ev.event_id {
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.fileLoaded = true
                        for s in self.pendingSubs {
                            self.command(["sub-add", s.url.absoluteString, "auto", s.title, s.lang ?? ""])
                        }
                        self.pendingSubs = []
                        self.onFileLoaded?()
                    }
                case MPV_EVENT_PLAYBACK_RESTART:
                    DispatchQueue.main.async { self.onPlaybackRestart?() }
                case MPV_EVENT_VIDEO_RECONFIG:
                    DispatchQueue.main.async { self.onVideoReconfig?() }
                case MPV_EVENT_END_FILE:
                    guard let data = ev.data else { break }
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_EOF {
                        DispatchQueue.main.async { self.onEnd?(.finished) }
                    } else if end.reason == MPV_END_FILE_REASON_ERROR {
                        let msg = String(cString: mpv_error_string(end.error))
                        DispatchQueue.main.async { self.onEnd?(.failed(msg)) }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
        }
    }

    // MARK: Apple TV display mode

    #if os(tvOS)
    var displaySignature: String { (string("video-params/gamma") ?? "") + "@" + String(double("container-fps") ?? 0) }

    /// Asks the TV to switch to the video's dynamic range and frame rate ("Match Content" in Apple TV Settings),
    /// like Apple's own player does. Returns true if a switch was requested.
    @MainActor @discardableResult
    func matchDisplay(in window: UIWindow?) -> Bool {
        guard let manager = window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled else { return false }
        let gamma = string("video-params/gamma") ?? ""
        let fps = Float(double("container-fps") ?? double("estimated-vf-fps") ?? 0)
        let w = Int32(int("video-params/w") ?? 1920), h = Int32(int("video-params/h") ?? 1080)
        var ext: [CFString: Any] = [:]
        switch gamma {
        case "pq":
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case "hlg":
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default:
            ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC, width: w, height: h,
                                       extensions: ext as CFDictionary, formatDescriptionOut: &desc)
        guard let desc else { return false }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: fps > 0 ? fps : 0, formatDescription: desc)
        return true
    }

    @MainActor static func resetDisplay(in window: UIWindow?) {
        window?.avDisplayManager.preferredDisplayCriteria = nil
    }
    #endif
}
#endif
