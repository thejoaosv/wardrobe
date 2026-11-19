import Foundation
import UIKit
import UserNotifications

/// Tells the user when AI work on the Mac finishes while the app is in the background.
/// iOS suspends apps quickly, so the wait is a background download that the server holds open until its work is done;
/// iOS wakes the app when it completes and a local notification is posted.
nonisolated final class Notifier: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let identifier = "dev.wardrobe.app.wait"
    private static let reviewsKey = "notifiedReviews"

    private let lock = NSLock()
    private var backgroundCompletion: (() -> Void)?

    // Static lets are initialized lazily and thread-safely; the session must exist once per identifier.
    private static let backgroundSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 15 * 60
        // Background sessions wait for a network indefinitely by default; a wait stuck that long is replaced instead.
        configuration.timeoutIntervalForResource = 60 * 60
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

    /// Starts one wait unless one to this server is already in flight. since is the Mac's time the wait looks back to;
    /// reviews is how many pieces the user has already been shown as waiting, so they aren't announced again.
    @MainActor func arm(base: URL, since: Date, reviews: Int) async {
        UserDefaults.standard.set(reviews, forKey: Self.reviewsKey)
        let tasks = await session.allTasks
        // A wait to another address (the server moved) would never report back; replace it.
        guard !tasks.contains(where: { $0.originalRequest?.url?.host == base.host && $0.originalRequest?.url?.port == base.port }) else { return }
        tasks.forEach { $0.cancel() }
        start(base: base, since: Int(since.timeIntervalSince1970 * 1000))
    }

    /// since is the server's cursor from the previous wait, so results landing between waits aren't skipped.
    private func start(base: URL, since: Int) {
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
        // The Mac counts every piece awaiting review, so only a rise is news.
        if result.reviews > UserDefaults.standard.integer(forKey: Self.reviewsKey) {
            Self.post("Ready to review", result.reviews == 1 ? "1 piece is waiting for you." : "\(result.reviews) pieces are waiting for you.")
        }
        UserDefaults.standard.set(result.reviews, forKey: Self.reviewsKey)
        // The server caps each wait; keep waiting while it still has work.
        // An absolute path resolves against the finished request's host, which survives an app relaunch.
        if result.busy, let url = downloadTask.originalRequest?.url {
            start(base: url, since: result.cursor ?? Int(Date.now.timeIntervalSince1970 * 1000))
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
