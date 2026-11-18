import SwiftUI
import AVKit

struct PlayerScreen: View {
    let request: PlaybackRequest
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel?
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                VideoPlayerController(player: model.player).ignoresSafeArea()

                if model.isLoading && model.errorMessage == nil {
                    ProgressView().tint(.white).scaleEffect(1.5)
                }

                if let error = model.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text("Couldn't play this").font(.headline)
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Stream info") { showInfo = true }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding()
                }
            }

            VStack {
                HStack {
                    overlayButton("xmark") { close() }
                    Spacer()
                    overlayButton("info.circle") { showInfo = true }
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                Spacer()
            }
        }
        .statusBarHidden()
        .task {
            guard model == nil else { return }
            let m = PlayerModel(request: request, client: app.client, maxBitrate: app.maxBitrate)
            model = m
            await m.start()
        }
        .onDisappear { Task { await model?.stop() } }
        .sheet(isPresented: $showInfo) {
            if let model { StreamInfoView(diagnostics: model.diagnostics) }
        }
    }

    private func overlayButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
    }

    private func close() {
        Task {
            await model?.stop()
            dismiss()
        }
    }
}

struct VideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}

struct StreamInfoView: View {
    let diagnostics: StreamDiagnostics

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    row("Method", diagnostics.playMethod)
                    row("Server video", diagnostics.serverVideo)
                    row("Server audio", diagnostics.serverAudio)
                    row("Decoder sees", diagnostics.decodedFormat)
                    row("Server reasons", diagnostics.transcodeReasons)
                }
                Section("Source file") {
                    row("Container", diagnostics.container)
                    row("Video", diagnostics.videoCodec)
                    row("Resolution", diagnostics.resolution)
                    row("Dynamic range", diagnostics.videoRange)
                    row("Dolby Vision", diagnostics.dolbyVisionProfile)
                    row("Bitrate", diagnostics.bitrate)
                    row("Audio", diagnostics.audio)
                }
                Section("This device") {
                    row("Dolby Vision", DeviceCapabilities.dolbyVision ? "Supported" : "Not supported")
                    row("HDR10", DeviceCapabilities.hdr10 ? "Supported" : "Not supported")
                    row("HEVC hardware", DeviceCapabilities.hevc ? "Yes" : "No")
                    row("AV1 hardware", DeviceCapabilities.av1 ? "Yes" : "No")
                }
            }
            .navigationTitle("Stream Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
