import AVKit
import SwiftUI

/// Real Picture in Picture: when the video pops out, the full-screen player closes so you can keep using Huefin
/// (or other apps) while it plays in the corner. Tapping "back to full screen" in the little window reopens the
/// player right where you are; closing the little window ends playback and saves your spot.
@MainActor
final class PiPSession: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPSession()

    /// The player screen currently on screen (it could pop out at any moment).
    private struct Candidate {
        let model: PlayerModel
        let request: PlaybackRequest
        let handle: VideoSurfaceHandle
        let dismiss: () -> Void
    }
    private var candidate: Candidate?

    /// The video playing in the little window right now.
    private var floating: Candidate?
    /// Did the full-screen player close when it popped out? (Only when you tap the PiP button inside the app.
    /// Swiping home leaves it in place, so coming back is instant.)
    private var screenClosed = false
    /// Set just before the PiP button starts it, to tell a button press from a swipe home.
    var startedByButton = false

    override init() {
        super.init()
        // Back in the app after swiping home: shrink the little window straight back into the full-screen player.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let f = PiPSession.shared.floating, !PiPSession.shared.screenClosed,
                      f.handle.pip?.isPictureInPictureActive == true else { return }
                f.handle.pip?.stopPictureInPicture()
            }
        }
    }
    private var restoreDone: ((Bool) -> Void)?
    private(set) var restoring = false

    var isFloating: Bool { floating != nil }

    /// Is this model being kept alive in the little window? (Then closing its screen must not stop it.)
    func owns(_ model: PlayerModel?) -> Bool {
        guard let model, let f = floating else { return false }
        return f.model === model
    }

    /// Called by Apple's player screen once its video is set up.
    func register(model: PlayerModel, request: PlaybackRequest, handle: VideoSurfaceHandle, dismiss: @escaping () -> Void) {
        candidate = Candidate(model: model, request: request, handle: handle, dismiss: dismiss)
        handle.pip?.delegate = self
        handle.onPiPCreated = { [weak self] pip in pip.delegate = self }
    }

    func unregister(_ model: PlayerModel?) {
        if let model, candidate?.model === model { candidate = nil }
    }

    /// A reopened player screen takes the floating video back.
    func adopt() -> PlayerModel? {
        guard restoring, let f = floating else { return nil }
        let done = restoreDone
        restoreDone = nil
        // Let the new screen draw its first frame, then shrink the little window back into it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            done?(true)
        }
        return f.model
    }

    /// Something else is about to play: close the little window and stop its video.
    func endForNewVideo() async {
        guard let f = floating, !restoring else { return }
        floating = nil
        f.handle.pip?.stopPictureInPicture()
        await f.model.stop()
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard let c = candidate, c.handle.pip === controller else { return }
            floating = c
            candidate = nil
            restoring = false
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard let f = floating, f.handle.pip === controller else { return }
            let byButton = startedByButton
            startedByButton = false
            // Tapped PiP inside the app: close the full-screen player so you can browse while it plays in the corner.
            // Swiped home: leave everything as it is; the system takes care of the rest.
            if byButton && UIApplication.shared.applicationState == .active {
                screenClosed = true
                f.dismiss()
            } else {
                screenClosed = false
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            startedByButton = false
            if let f = floating, f.handle.pip === controller { candidate = f; floating = nil }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard let f = floating, f.handle.pip === controller else { completionHandler(false); return }
            restoring = true
            if !screenClosed {
                // The full-screen player never went away; the video slides straight back into it.
                completionHandler(true)
                return
            }
            restoreDone = completionHandler
            AppRouter.shared.playRequest = PlaybackRequest(item: f.request.item, startTicks: f.request.startTicks,
                                                           localDownload: f.request.localDownload,
                                                           mediaSourceId: f.request.mediaSourceId, forceApple: true)
            // If the player can't reopen for some reason, don't leave iOS waiting.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if let done = self?.restoreDone { self?.restoreDone = nil; done(false) }
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard let f = floating, f.handle.pip === controller else { return }
            floating = nil
            if restoring {
                restoring = false            // back in the full-screen player, which now owns the video
                if !screenClosed { candidate = f } // same screen keeps going; it can pop out again
                screenClosed = false
            } else if screenClosed {
                Task { await f.model.stop() } // closed the little window: stop and save your spot
            } else {
                candidate = f                 // player screen is still open underneath; just stay put (paused)
            }
            screenClosed = false
        }
    }
}
