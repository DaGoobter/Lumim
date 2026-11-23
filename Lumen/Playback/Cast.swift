import SwiftUI
#if canImport(GoogleCast)
import GoogleCast

/// Chromecast: send what's playing to a Google TV, Chromecast or Cast-enabled TV.
@MainActor @Observable
final class CastManager: NSObject, GCKSessionManagerListener, GCKRemoteMediaClientListener {
    static let shared = CastManager()
    private(set) var deviceName: String?
    private(set) var isPlaying = false
    @ObservationIgnored private var started = false

    var isCasting: Bool { deviceName != nil }

    func setUp() {
        guard !started else { return }
        started = true
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    private var client: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    /// Cast this item at this position. Uses a stream every Cast device can play (H.264/AAC HLS).
    func cast(item: BaseItem, startSeconds: Double, api: JellyfinClient) {
        guard let remote = client else { return }
        let url = api.url("Videos/\(item.id)/master.m3u8", query: [
            "MediaSourceId": item.mediaSources?.first?.id ?? item.id,
            "DeviceId": JellyfinClient.deviceId + "-cast",
            "VideoCodec": "h264", "AudioCodec": "aac", "MaxStreamingBitrate": "20000000",
            "TranscodingMaxAudioChannels": "2", "SegmentContainer": "ts", "api_key": api.accessToken,
        ])
        let meta = GCKMediaMetadata(metadataType: item.type == "Episode" ? .tvShow : .movie)
        meta.setString(item.displayTitle, forKey: kGCKMetadataKeyTitle)
        if let ep = item.episodeLabel { meta.setString(ep, forKey: kGCKMetadataKeySubtitle) }
        meta.addImage(GCKImage(url: api.backdropURL(for: item, width: 1280), width: 1280, height: 720))
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.streamType = .buffered
        builder.contentType = "application/x-mpegURL"
        builder.metadata = meta
        let options = GCKMediaLoadOptions()
        options.playPosition = startSeconds
        options.autoplay = true
        remote.loadMedia(builder.build(), with: options)
        isPlaying = true
    }

    func togglePlay() {
        guard let c = client else { return }
        if isPlaying { c.pause() } else { c.play() }
        isPlaying.toggle()
    }

    func stopCasting() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    // MARK: Session events

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        let name = session.device.friendlyName
        Task { @MainActor in
            self.deviceName = name ?? "TV"
            // Hand over what's playing on the phone.
            if let player = PlayerModel.active, let api = player.castClient {
                self.cast(item: player.item, startSeconds: player.currentTime, api: api)
                player.syncPause()
            }
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        Task { @MainActor in self.deviceName = nil; self.isPlaying = false }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        let name = session.device.friendlyName
        Task { @MainActor in self.deviceName = name ?? "TV" }
    }
}

/// Google's Cast button (finds Chromecasts on the Wi-Fi).
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let b = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        b.tintColor = .white
        return b
    }
    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}
#endif

/// "Playing on Living Room TV" panel over the player while casting.
struct CastingOverlay: View {
    var body: some View {
        #if canImport(GoogleCast)
        let cast = CastManager.shared
        if let name = cast.deviceName {
            VStack(spacing: 16) {
                Image(systemName: "tv.and.mediabox").font(.system(size: 44)).foregroundStyle(Theme.spectrum)
                Text("Playing on \(name)").font(.headline)
                HStack(spacing: 14) {
                    Button { cast.togglePlay() } label: {
                        Label(cast.isPlaying ? "Pause" : "Play", systemImage: cast.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button(role: .destructive) { cast.stopCasting() } label: { Label("Stop casting", systemImage: "stop.fill") }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        #endif
    }
}
