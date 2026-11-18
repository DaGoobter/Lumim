import AVFoundation
import Foundation

/// The DJ's voice. Neural voices (Kokoro on your own server, OpenAI, ElevenLabs) sound human; the
/// iPhone's built-in speech is the fallback. Intros are fetched ahead of time so they start instantly.
@MainActor
final class DJVoice: NSObject {
    static let shared = DJVoice()

    enum Engine: String, CaseIterable, Identifiable {
        case kokoro, openAI, elevenLabs, iPhone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .kokoro: return "Kokoro on my PC (free)"
            case .openAI: return "OpenAI"
            case .elevenLabs: return "ElevenLabs"
            case .iPhone: return "iPhone voice"
            }
        }
    }

    // MARK: Settings (UserDefaults; API keys in the Keychain)

    private let defaults = UserDefaults.standard

    var engine: Engine {
        get { Engine(rawValue: defaults.string(forKey: "dj.engine") ?? "") ?? .iPhone }
        set { defaults.set(newValue.rawValue, forKey: "dj.engine"); cache.removeAll() }
    }
    var kokoroURL: String {
        get { defaults.string(forKey: "dj.kokoroURL") ?? "" }
        set { defaults.set(newValue, forKey: "dj.kokoroURL"); cache.removeAll() }
    }
    /// Optional address for Kokoro away from home (e.g. through Caddy). Tried when the home address can't be reached.
    var kokoroRemoteURL: String {
        get { defaults.string(forKey: "dj.kokoroRemoteURL") ?? "" }
        set { defaults.set(newValue, forKey: "dj.kokoroRemoteURL"); cache.removeAll() }
    }
    var kokoroVoice: String {
        get { defaults.string(forKey: "dj.kokoroVoice") ?? "af_heart" }
        set { defaults.set(newValue, forKey: "dj.kokoroVoice"); cache.removeAll() }
    }
    /// Talking pace for Kokoro. Radio hosts talk a touch faster than an audiobook narrator.
    var kokoroSpeed: Double {
        get { defaults.object(forKey: "dj.kokoroSpeed") as? Double ?? 1.1 }
        set { defaults.set(newValue, forKey: "dj.kokoroSpeed"); cache.removeAll() }
    }
    var openAIVoice: String {
        get { defaults.string(forKey: "dj.openAIVoice") ?? "coral" }
        set { defaults.set(newValue, forKey: "dj.openAIVoice"); cache.removeAll() }
    }
    var elevenVoice: String {
        get { defaults.string(forKey: "dj.elevenVoice") ?? "21m00Tcm4TlvDq8Ikz7M" }
        set { defaults.set(newValue, forKey: "dj.elevenVoice"); cache.removeAll() }
    }
    var openAIKey: String {
        get { Keychain.load("dj.openAIKey").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set { Keychain.save(Data(newValue.utf8), key: "dj.openAIKey"); cache.removeAll() }
    }
    var elevenKey: String {
        get { Keychain.load("dj.elevenKey").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set { Keychain.save(Data(newValue.utf8), key: "dj.elevenKey"); cache.removeAll() }
    }

    // MARK: Script markup

    private static let pauseTag = try! NSRegularExpression(pattern: #"\s*\[pause:(\d+(?:\.\d+)?)s\]\s*"#, options: .caseInsensitive)

    /// The line as it should appear on screen (no pause markers).
    static func display(_ text: String) -> String {
        replacePauses(in: text) { _ in " " }
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The line in the form each voice understands best.
    private func spoken(_ text: String) -> String {
        switch engine {
        case .kokoro: return text
        case .elevenLabs: return Self.replacePauses(in: text) { #" <break time="\#($0)s" /> "# }
        case .openAI: return Self.replacePauses(in: text) { Double($0) ?? 0 >= 0.35 ? " ... " : " " }
        case .iPhone: return Self.display(text)
        }
    }

    private static func replacePauses(in text: String, with make: (String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in pauseTag.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += make(ns.substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Speaking

    private var cache: [String: Data] = [:]
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var lastError: String?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// Start generating the audio for an intro now, so it's ready when the set begins.
    func prefetch(_ text: String) {
        guard engine != .iPhone, cache[text] == nil else { return }
        Task { _ = await audio(for: text) }
    }

    /// Speak and return when finished. Neural engines that can't be reached stay silent (the line still
    /// shows on screen) rather than falling back to the robotic voice.
    func say(_ text: String) async {
        stop()
        if engine == .iPhone {
            await speakSystem(text)
            return
        }
        guard let data = await audio(for: text), let p = try? AVAudioPlayer(data: data) else { return }
        player = p
        p.delegate = self
        p.volume = 1
        p.play()
        await withCheckedContinuation { continuation = $0 }
    }

    func stop() {
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        let c = continuation
        continuation = nil
        c?.resume()
    }

    private func speakSystem(_ text: String) async {
        let u = AVSpeechUtterance(string: spoken(text))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        u.voice = voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.48
        u.pitchMultiplier = 1.05
        synth.speak(u)
        await withCheckedContinuation { continuation = $0 }
    }

    // MARK: Neural voices

    /// The Kokoro address that answered last, so we don't keep waiting on the home address while away.
    private var preferredKokoroBase: String?

    private func audio(for text: String) async -> Data? {
        if let hit = cache[text] { return hit }
        var bases: [String?] = [nil]
        if engine == .kokoro {
            var list = [Self.normalize(kokoroURL), Self.normalize(kokoroRemoteURL)].filter { !$0.isEmpty }
            if let p = preferredKokoroBase, let i = list.firstIndex(of: p) { list.insert(list.remove(at: i), at: 0) }
            bases = list.isEmpty ? [""] : list
        }
        for (i, base) in bases.enumerated() {
            guard let request = makeRequest(text, kokoroBase: base) else { return nil }
            let config = URLSessionConfiguration.ephemeral
            // A home address that isn't reachable should fail fast so the away address gets its turn.
            config.timeoutIntervalForRequest = i < bases.count - 1 ? 4 : 15
            do {
                let (data, response) = try await URLSession(configuration: config).data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 500 else {
                    lastError = "The voice service answered with an error (\((response as? HTTPURLResponse)?.statusCode ?? 0))."
                    continue
                }
                lastError = nil
                if let base { preferredKokoroBase = base }
                cache[text] = data
                return data
            } catch {
                lastError = error.localizedDescription
            }
        }
        return nil
    }

    private func makeRequest(_ text: String, kokoroBase: String?) -> URLRequest? {
        switch engine {
        case .iPhone:
            return nil
        case .kokoro, .openAI:
            let base = engine == .openAI ? "https://api.openai.com/v1" : (kokoroBase ?? "")
            guard let url = URL(string: base + "/audio/speech") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["input": spoken(text), "response_format": "mp3"]
            if engine == .openAI {
                guard !openAIKey.isEmpty else { lastError = "Add your OpenAI API key."; return nil }
                req.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
                body["model"] = "gpt-4o-mini-tts"
                body["voice"] = openAIVoice
                body["instructions"] = "You're a charismatic radio DJ talking to one friend, not reading a script. "
                    + "Loose, warm and playful, with a smile in your voice. Vary your pace: breeze through the "
                    + "chatty bits, then slow down slightly and land the song title and artist like a reveal. "
                    + "Natural breaths, a little laugh where it fits. Never monotone, never announcer-stiff."
            } else {
                body["model"] = "kokoro"
                body["voice"] = kokoroVoice
                body["speed"] = kokoroSpeed
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        case .elevenLabs:
            guard !elevenKey.isEmpty,
                  let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenVoice)?output_format=mp3_44100_128")
            else { lastError = "Add your ElevenLabs API key."; return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(elevenKey, forHTTPHeaderField: "xi-api-key")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": spoken(text), "model_id": "eleven_flash_v2_5",
                "voice_settings": ["stability": 0.4, "similarity_boost": 0.8, "style": 0.35],
            ] as [String: Any])
            return req
        }
    }

    /// Accepts "192.168.1.20:8880", "http://host:8880", "https://host/path" or ".../v1".
    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/v1") { s += "/v1" }
        return s
    }
}

extension DJVoice: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in DJVoice.shared.finish() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in DJVoice.shared.finish() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in DJVoice.shared.finish() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in DJVoice.shared.finish() }
    }
}
