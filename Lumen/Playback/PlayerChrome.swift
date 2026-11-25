import SwiftUI

/// The look of the player controls: dark round buttons, a big play button in the middle,
/// and the progress bar in a rounded pill at the bottom. Shared by Apple's player and the Huefin Engine.
enum PlayerChrome {
    static let button: CGFloat = 50
    static let skip: CGFloat = 68
    static let play: CGFloat = 84
    static let fill = Color(white: 0.11).opacity(0.86)
}

extension View {
    /// A dark round button face of the given size.
    func playerCircle(_ size: CGFloat = PlayerChrome.button) -> some View {
        self
            .frame(width: size, height: size)
            .background(PlayerChrome.fill, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .foregroundStyle(.white)
            .contentShape(Circle())
    }

    /// The same dark face, stretched into a pill.
    func playerPill(height: CGFloat = PlayerChrome.button) -> some View {
        self
            .frame(height: height)
            .background(PlayerChrome.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .foregroundStyle(.white)
    }
}

/// A plain round icon button for the player.
struct PlayerCircleButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = PlayerChrome.button
    var iconSize: CGFloat = 19
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .playerCircle(size)
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }
}

struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Back · Play/Pause · Forward, each in its own circle.
struct PlayerTransport: View {
    let isPlaying: Bool
    var showSkips = true
    let onBack: () -> Void
    let onToggle: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 30) {
            if showSkips {
                PlayerCircleButton(symbol: "gobackward.\(PlaybackPrefs.skipBack)", label: "Back \(PlaybackPrefs.skipBack) seconds",
                                   size: PlayerChrome.skip, iconSize: 27, action: onBack)
            }
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .playerCircle(PlayerChrome.play)
            }
            .buttonStyle(PlayerPressStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            if showSkips {
                PlayerCircleButton(symbol: "goforward.\(PlaybackPrefs.skipForward)", label: "Forward \(PlaybackPrefs.skipForward) seconds",
                                   size: PlayerChrome.skip, iconSize: 27, action: onForward)
            }
        }
    }
}

/// Elapsed time, a slim draggable bar, and time remaining, inside a pill.
struct PlayerScrubPill<Track: View, Bubble: View>: View {
    let current: Double
    let duration: Double
    @Binding var scrubbing: Bool
    @Binding var scrubValue: Double
    let onCommit: (Double) -> Void
    @ViewBuilder var track: () -> Track      // chapter ticks, drawn behind the bar
    @ViewBuilder var bubble: () -> Bubble    // preview shown above the bar while dragging

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        let shown = scrubbing ? scrubValue : current
        HStack(spacing: 14) {
            Text(clock(shown)).frame(minWidth: 38, alignment: .leading)
            GeometryReader { g in
                let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: scrubbing ? 7 : 5)
                    track()
                    Capsule().fill(.white).frame(width: max(0, g.size.width * frac), height: scrubbing ? 7 : 5)
                    Circle().fill(.white)
                        .frame(width: scrubbing ? 18 : 11, height: scrubbing ? 18 : 11)
                        .offset(x: g.size.width * frac - (scrubbing ? 9 : 5.5))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !scrubbing { scrubbing = true }
                            scrubValue = max(0, min(duration, Double(v.location.x / max(1, g.size.width)) * duration))
                        }
                        .onEnded { _ in onCommit(scrubValue); scrubbing = false }
                )
                .overlay(alignment: .bottomLeading) { if scrubbing { bubble() } }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: scrubbing)
            }
            Text("-" + clock(max(0, duration - shown))).frame(minWidth: 46, alignment: .trailing)
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 18)
        .playerPill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(clock(shown)) of \(clock(duration))")
        .accessibilityAdjustableAction { dir in
            let step = Double(dir == .increment ? PlaybackPrefs.skipForward : -PlaybackPrefs.skipBack)
            onCommit(max(0, min(duration, current + step)))
        }
    }
}

/// "1×" in a circle; tap for speeds.
struct PlayerSpeedMenu: View {
    let speed: Float
    let onPick: (Float) -> Void
    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private func label(_ s: Float) -> String { s == 1 ? "1×" : String(format: "%g×", s) }

    var body: some View {
        Menu {
            Section("Speed") {
                ForEach(speeds, id: \.self) { s in
                    Button { onPick(s) } label: {
                        if s == speed { Label(s == 1 ? "Normal" : label(s), systemImage: "checkmark") }
                        else { Text(s == 1 ? "Normal" : label(s)) }
                    }
                }
            }
        } label: {
            Text(label(speed))
                .font(.system(size: 17, weight: .bold))
                .minimumScaleFactor(0.7)
                .playerCircle()
        }
        .accessibilityLabel("Playback speed")
    }
}
