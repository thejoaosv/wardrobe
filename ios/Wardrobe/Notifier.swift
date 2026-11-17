import Foundation
import UIKit
import UserNotifications

/// Tells the user when AI work on the Mac finishes while the app is in the background.
/// iOS suspends apps quickly, so the wait is a background download that the server holds open until its work is done;
/// iOS wakes the app when it completes and a local notification is posted.
nonisolated final class Notifier: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let identifier = "dev.wardrobe.app.wait"

    private let lock = NSLock()
    private var backgroundCompletion: (() -> Void)?

    // Static lets are initialized lazily and thread-safely; the session must exist once per identifier.
    private static let backgroundSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 15 * 60
        return URLSession(configuration: configuration, delegate: shared, delegateQueue: nil)
    }()
    private var session: URLSession { Self.backgroundSession }

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Starts one wait unless one is already in flight.
    /// Called as the app backgrounds; the assertion keeps it alive until iOS owns the request.
    @MainActor func arm(base: URL) {
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "arm-wait")
        session.getAllTasks { tasks in
            if tasks.isEmpty { self.start(base: base) }
            Task { @MainActor in UIApplication.shared.endBackgroundTask(assertion) }
        }
    }

    /// since is the server's cursor from the previous wait, so results landing between waits aren't skipped.
    private func start(base: URL, since: Int = Int(Date.now.timeIntervalSince1970 * 1000)) {
        guard let url = URL(string: "/api/import/wait?since=\(since)", relativeTo: base) else { return }
        session.downloadTask(with: url).resume()
    }

    /// Called from the app delegate when iOS relaunches the app for this session's events.
    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.identifier else { return completion() }
        lock.withLock { backgroundCompletion = completion }
        _ = session
    }

    private struct Result: Decodable {
        struct TryOn: Decodable { let name: String; let status: String; var side: String? }
        let busy: Bool
        let reviews: Int
        let tryOns: [TryOn]
        let backs: [TryOn]?
        let cursor: Int?
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let data = try? Data(contentsOf: location), let result = try? JSONDecoder().decode(Result.self, from: data) else { return }
        for tryOn in result.tryOns {
            if tryOn.status == "ready" { Self.post("Your try-on is ready", "See yourself in \(tryOn.name).") }
            else { Self.post("Try-on didn't work", "Open \(tryOn.name) to try again.") }
        }
        for back in result.backs ?? [] {
            if back.side == "front" {
                if back.status == "ready" { Self.post("New cutout ready", "\(back.name) has a fresh cutout.") }
                else { Self.post("Cutout didn't work", "Open \(back.name) to try again.") }
            } else if back.status == "ready" { Self.post("Back cutout ready", "\(back.name) now has its back photo.") }
            else { Self.post("Back cutout didn't work", "Open \(back.name) to try again.") }
        }
        if result.reviews > 0 {
            Self.post("Ready to review", result.reviews == 1 ? "1 piece is waiting for you." : "\(result.reviews) pieces are waiting for you.")
        }
        // The server caps each wait; keep waiting while it still has work.
        // An absolute path resolves against the finished request's host, which survives an app relaunch.
        if result.busy, let url = downloadTask.originalRequest?.url {
            if let cursor = result.cursor { start(base: url, since: cursor) } else { start(base: url) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        DispatchQueue.main.async { completion?() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Notifier.shared.handleEvents(identifier: identifier, completion: completionHandler)
    }
}
