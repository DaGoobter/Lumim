import XCTest
@testable import Lumen

/// Plays every clip in the test pack through the native engine's self test.
/// Clips come from scripts/make-test-clips.sh (synthetic, made fresh in CI) or, on a developer machine,
/// from the private test pack cut from the real library. Folder: CLIPS_DIR environment variable.
final class EngineClipTests: XCTestCase {
    private var clipsDir: URL? {
        ProcessInfo.processInfo.environment["CLIPS_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func testEveryClip() throws {
        guard let dir = clipsDir else { throw XCTSkip("CLIPS_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "No clips found in \(dir.path)")
        var report: [String] = []
        for file in files {
            let name = file.lastPathComponent
            // Hard limit per clip so a hang fails the build instead of stalling it.
            var result: EngineSelfTest?
            let done = expectation(description: name)
            DispatchQueue.global().async {
                result = NativeCore.selfTest(path: file.path)
                done.fulfill()
            }
            if XCTWaiter().wait(for: [done], timeout: 30) != .completed {
                XCTFail("\(name): engine hung for 30 s"); report.append("\(name): HUNG"); continue
            }
            guard let r = result else { continue }
            report.append("\(name): \(r)")

            // Expectations that must hold for every file.
            XCTAssertEqual(r.audioDecodable, r.audioTracks, "\(name): an audio track can't be decoded")
            XCTAssertEqual(r.subtitleDecodable, r.subtitleTracks, "\(name): a subtitle track can't be read")
            if let gap = r.startGap { XCTAssertLessThan(gap, 1.0, "\(name): audio and video start \(gap) s apart") }

            // Files the native engine must show itself (H.264/HEVC 8–10 bit, including hidden-setup files).
            let mustBeNative = name.hasPrefix("native_")
            if mustBeNative {
                XCTAssertTrue(r.nativeVideo, "\(name): native engine couldn't show the picture (\(r.fallbackReason ?? "?"))")
            }
            if r.nativeVideo {
                XCTAssertTrue(r.seekOK, "\(name): jumping to the middle didn't produce a picture")
                // The simulator decodes in software; odd clips (interlaced) vary a lot there, so they get more room.
                XCTAssertLessThan(r.firstFrameSeconds, mustBeNative ? 5 : 10, "\(name): first picture took \(r.firstFrameSeconds) s")
            } else {
                XCTAssertNotNil(r.fallbackReason, "\(name): not native and no reason given")
            }
        }
        let text = report.joined(separator: "\n")
        print("ENGINE REPORT\n" + text)
        let attachment = XCTAttachment(string: text)
        attachment.name = "engine-report.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
