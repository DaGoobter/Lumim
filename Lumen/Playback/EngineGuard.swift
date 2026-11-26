import Foundation
import MetricKit

/// Safety switch for the Huefin Engine on iPhone/iPad.
/// If the app dies while the engine is starting a video, the next launch notices and plays everything in
/// Apple's player instead, until a new build of Huefin is installed. So a bad engine can never lock you out
/// of watching.
enum EngineGuard {
    private static let startingKey = "huefin.engineStartingBuild"
    private static let trippedKey = "huefin.engineTrippedBuild"
    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// Call once at launch.
    static func checkLastRun() {
        let d = UserDefaults.standard
        if d.string(forKey: startingKey) == build { d.set(build, forKey: trippedKey) }
        d.removeObject(forKey: startingKey)
        CrashReporter.shared.start()
    }

    /// True when the engine crashed on this build: use Apple's player for everything.
    static var tripped: Bool { UserDefaults.standard.string(forKey: trippedKey) == build }

    static func engineStarting() { UserDefaults.standard.set(build, forKey: startingKey) }
    static func engineSurvived() { UserDefaults.standard.removeObject(forKey: startingKey) }
}

/// Collects Apple's crash reports for Huefin (delivered on the next launch) and sends them to your
/// Jellyfin server's log folder, so a crash can be read and fixed without needing the phone.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CrashReports", isDirectory: true)

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads where !(p.crashDiagnostics ?? []).isEmpty {
            let name = "crash-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try? p.jsonRepresentation().write(to: folder.appendingPathComponent(name))
        }
    }

    /// Upload any saved crash reports to the server (POST /ClientLog/Document), then delete them.
    func upload(baseURL: URL, authorization: String) async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            var text = Data("Huefin iOS crash report (build \(build))\n".utf8)
            text.append(data)
            var req = URLRequest(url: baseURL.appendingPathComponent("ClientLog/Document"))
            req.httpMethod = "POST"
            req.setValue(authorization, forHTTPHeaderField: "Authorization")
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            req.httpBody = text
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
