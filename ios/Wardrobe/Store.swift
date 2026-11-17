import Foundation
import Observation
import UIKit

nonisolated struct Item: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var part: String
    var color: String?
    var secondaryColor: String?
    /// What a stylist needs to know: fabric, fit, warmth, formality.
    var description: String?
    /// Exact printed or embroidered text, with placement; empty when there is none.
    var text: String?
    var tags: [String]?
    var image: String?
    var modeledImage: String?
    var backImage: String?
    var back: Cutout?
    /// A redo of the front cutout, while it runs and after.
    var front: Cutout?
    var unavailable: Bool?
    /// Wears before it needs washing; nil follows the category default.
    var wears: Int?

    var isAvailable: Bool { unavailable != true }

    /// warnings are what the AI reviewer still saw wrong after its retries.
    struct Cutout: Codable, Hashable { var status: String; var error: String?; var warnings: [String]? }
}

nonisolated struct Plan: Codable, Identifiable, Hashable {
    var id: String { date }
    let date: String
    var style: String
    var weather: String?
    var name: String
    var garmentIds: [String]
    var reason: String
    var repeats: [String]?
    var tryOn: TryOn?

    struct TryOn: Codable, Hashable {
        var status: String
        var image: String?
        var error: String?
        var warnings: [String]?
    }
}

nonisolated struct Job: Codable, Identifiable, Hashable {
    struct Metadata: Codable, Hashable { var name: String; var part: String }
    struct Stage: Codable, Hashable { var status: String; var assetUrl: String?; var error: String?; var warnings: [String]? }
    struct Stages: Codable, Hashable { var crop: Stage?; var garment: Stage; var modeled: Stage }
    let id: String
    var metadata: Metadata
    var stages: Stages

    /// The first stage still waiting on generation or review.
    var current: (name: String, stage: Stage) {
        if let crop = stages.crop, crop.status != "approved" { return ("crop", crop) }
        if stages.garment.status != "approved" { return ("garment", stages.garment) }
        return ("modeled", stages.modeled)
    }
}

nonisolated struct ServerConfig: Codable {
    var ready: Bool
    var provider: String?
    var hasModelReference: Bool
    var modelReference: String
}

nonisolated struct ServerVersion: Codable {
    struct Release: Codable, Hashable { var version: String; var date: String?; var notes: [String] }
    var version: String
    var api: Int
    var changelog: [Release]
}

/// Choices stored on the Mac, shared by every device.
nonisolated struct ServerSettings: Codable {
    var checks: String
    /// Wears before washing by category; nil from servers before 1.3.
    var wears: [String: Int]?
}

/// A photo the Mac is searching for clothes in the background.
nonisolated struct Detection: Codable, Identifiable, Hashable {
    let id: String
    var status: String
    var message: String?
    var found: Int
    var error: String?
    var isWorking: Bool { status == "working" }
}

/// A day the Mac is styling in the background; failed ones wait until the app has shown them.
nonisolated struct Styling: Codable, Hashable {
    let date: String
    var status: String
    var error: String?
}

struct PlanDay: Hashable { var date: Date; var style: String; var weather = "auto"; var replace: String? = nil }

nonisolated enum Parts {
    static let order = ["upperbody", "midlayer", "wholebody_up", "lowerbody", "shoes", "accessories_up"]
    /// Mirrors DEFAULT_WEARS in scripts/outfit-planner.mjs, for servers that don't send their own.
    static let defaultWears = ["upperbody": 1, "midlayer": 3, "lowerbody": 3, "wholebody_up": 5, "shoes": 7, "accessories_up": 7]
    static func label(_ part: String) -> String {
        ["upperbody": "Tops", "midlayer": "Sweaters & hoodies", "wholebody_up": "Jackets", "lowerbody": "Bottoms", "shoes": "Shoes", "accessories_up": "Accessories"][part] ?? part
    }
}

enum Day {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ string: String) -> Date { formatter.date(from: string) ?? .now }
    static var today: String { string(.now) }
}

struct ServerError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@Observable
final class Store {
    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:5173" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var items: [Item] = []
    var plans: [Plan] = []
    var jobs: [Job] = []
    var config: ServerConfig?
    /// nil when the server predates versions.
    var version: ServerVersion?
    var settings: ServerSettings?
    /// Changes when the photo of the user is replaced, so its preview reloads.
    var referenceStamp = Date.now
    /// The oldest server API this app works with; see API_VERSION in scripts/import-job-api.mjs.
    static let minimumServerAPI = 5
    var serverIsOutdated: Bool { config != nil && (version?.api ?? 0) < Self.minimumServerAPI }
    var error: String?
    /// Open sheets; while one is up, it shows errors itself, because an alert on the root view would close it.
    var sheetDepth = 0
    /// Why the last refresh could not reach the server, shown in the Server sheet.
    var connectionError: String?
    /// The sheet the root view presents (chooser, plan or import).
    var sheet: AppSheet?
    /// Days the stylist is working on right now, by date; their weather shapes the loading skeleton.
    var planning: [String: PlanDay] = [:]
    var planningDates: Set<String> { Set(planning.keys).union(styling.filter { $0.status == "working" }.map(\.date)) }
    var styling: [Styling] = []
    /// Photos still uploading, then searched on the Mac.
    var uploading: [String] = []
    var detections: [Detection] = []
    /// Import jobs with a review action in flight, so their buttons can't be tapped twice.
    var reviewing: Set<String> = []
    /// What the AI is doing right now ("Checking the cutout…", "Retrying (2/3): …"), keyed like "job:<id>" or "plan:<date>".
    var progress: [String: String] = [:]

    // Long AI work runs in the background on the Mac, so every request here is short.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Errors worth one more try: Wi-Fi blips, a sleeping phone, or the server closing an idle connection as it was reused.
    private static let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost]

    /// The typed address, tolerating a missing scheme and stray whitespace.
    var baseURL: URL? {
        let typed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: typed.contains("://") ? typed : "http://\(typed)")
    }

    /// width asks the server for a WebP preview that size instead of the full PNG.
    func url(_ path: String?, width: Int? = nil) -> URL? {
        guard let path, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return nil }
        guard let width, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "w", value: String(width))]
        return components.url
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// retry repeats the request after a transient network error; only for requests the server handles safely twice.
    private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, retry: Bool? = nil) async throws -> T {
        guard let url = url(path) else { throw ServerError(message: "Invalid server address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let retries = retry ?? ["GET", "PATCH", "DELETE"].contains(method) ? 2 : 0
        var attempt = 0
        let (data, response): (Data, URLResponse)
        while true {
            do {
                (data, response) = try await session.data(for: request)
                break
            } catch let error as URLError where Self.transient.contains(error.code) && attempt < retries {
                attempt += 1
                try await Task.sleep(for: .milliseconds(700 * attempt))
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ServerError(message: message ?? "Server error \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs an action and surfaces failures as an alert instead of throwing.
    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch let error as URLError where Self.transient.contains(error.code) {
            print("Wardrobe request failed: \(error)")
            self.error = "Couldn't reach your Mac. Check that it's awake and on the same Wi-Fi, then try again."
        } catch {
            print("Wardrobe request failed: \(error)")
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        do {
            async let items: [Item] = send("/api/import/wardrobe")
            async let plans: [Plan] = send("/api/import/plans")
            async let config: ServerConfig = send("/api/import/config")
            async let jobs: [Job] = send("/api/import/jobs")
            (self.items, self.plans, self.config, self.jobs) = try await (items, plans, config, jobs)
            connectionError = nil
            // Older servers lack these; that is what serverIsOutdated reports.
            version = try? await send("/api/import/version")
            settings = try? await send("/api/import/settings")
            // Searches and styling may have finished while the app was away.
            if let latest: [Detection] = try? await send("/api/import/detections") { detections = latest }
            if !planning.isEmpty || !styling.isEmpty { await loadStyling() }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            print("Wardrobe could not reach \(serverURL): \(error)")
            config = nil
            connectionError = error.localizedDescription
        }
    }

    /// Wears before washing: the piece's own count, else the user's default for its category.
    func wearLimit(_ item: Item) -> Int {
        item.wears ?? defaultWears(item.part)
    }

    func defaultWears(_ part: String) -> Int {
        settings?.wears?[part] ?? Parts.defaultWears[part] ?? 1
    }

    func setDefaultWears(_ part: String, _ wears: Int) async {
        settings?.wears?[part] = wears
        await run { settings = try await send("/api/import/settings", method: "PATCH", body: ["wears": [part: wears]]) }
    }

    func setChecks(_ checks: String) async {
        await run { settings = try await send("/api/import/settings", method: "PATCH", body: ["checks": checks]) }
    }

    func uploadModelReference(_ jpeg: Data) async {
        await run {
            config = try await send("/api/import/model-reference", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
            referenceStamp = .now
        }
    }

    func setUnavailable(_ ids: [String], _ unavailable: Bool) async {
        await run { items = try await send("/api/import/wardrobe", method: "PATCH", body: ["ids": ids, "unavailable": unavailable]) }
    }

    func loadItems() async {
        await run { items = try await send("/api/import/wardrobe") }
    }

    /// Saves edited details; the server normalizes them and returns the stored piece.
    func update(_ item: Item) async {
        await run {
            var body: [String: Any] = ["name": item.name, "part": item.part, "tags": item.tags ?? [], "description": item.description ?? "", "text": item.text ?? ""]
            body["color"] = item.color
            body["secondaryColor"] = item.secondaryColor ?? NSNull()
            body["wears"] = item.wears ?? NSNull()
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)", method: "PATCH", body: body)
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
        }
    }

    /// nil redoes the back from the photo it already has.
    func addBack(_ item: Item, jpeg: Data?) async {
        await Notifier.requestPermission()
        await run {
            let body: [String: Any] = jpeg.map { ["imageDataUrl": "data:image/jpeg;base64,\($0.base64EncodedString())"] } ?? [:]
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)/back", method: "POST", body: body)
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
        }
    }

    /// Makes the front cutout again, from a new photo or else the photo kept at import.
    func redoCutout(_ item: Item, jpeg: Data? = nil) async {
        await Notifier.requestPermission()
        await run {
            let body: [String: Any] = jpeg.map { ["imageDataUrl": "data:image/jpeg;base64,\($0.base64EncodedString())"] } ?? [:]
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)/front", method: "POST", body: body)
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
        }
    }

    func removeBack(_ item: Item) async {
        await run {
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)/back", method: "DELETE")
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
        }
    }

    func delete(_ item: Item) async {
        await run {
            let _: [String: AnyCodable] = try await send("/api/import/wardrobe/\(item.id)", method: "DELETE")
            items.removeAll { $0.id == item.id }
        }
    }

    /// Starts styling on the Mac; poll() picks up the result, so leaving the app or losing Wi-Fi meanwhile loses nothing.
    func generate(_ days: [PlanDay]) async {
        let dates = days.map { Day.string($0.date) }
        for day in days { planning[Day.string(day.date)] = day }
        await run {
            let body = days.map { day in
                var entry = ["date": Day.string(day.date), "style": day.style, "weather": day.weather]
                entry["replace"] = day.replace
                return entry
            }
            styling = try await send("/api/import/plans", method: "POST", body: ["days": body, "background": true])
        }
        // Not started at all: nothing to wait for.
        for date in dates where !styling.contains(where: { $0.date == date && $0.status == "working" }) { planning[date] = nil }
    }

    /// One round of status checks while the AI works: live messages, photos being searched, days being styled.
    func poll() async {
        await loadProgress()
        if !detections.isEmpty || !uploading.isEmpty { await loadDetections() }
        if !planning.isEmpty || !styling.isEmpty { await loadStyling() }
    }

    func loadDetections() async {
        guard let latest: [Detection] = try? await send("/api/import/detections") else { return }
        let finished = detections.filter(\.isWorking).contains { old in latest.first { $0.id == old.id }?.isWorking != true }
        detections = latest
        if finished { await loadJobs() }
    }

    func dismissDetection(_ detection: Detection) async {
        detections.removeAll { $0.id == detection.id }
        await run { detections = try await send("/api/import/detections/\(detection.id)", method: "DELETE") }
    }

    func loadStyling() async {
        guard let latest: [Styling] = try? await send("/api/import/plans/styling") else { return }
        styling = latest
        let working = Set(latest.filter { $0.status == "working" }.map(\.date))
        let done = planning.keys.filter { !working.contains($0) }
        for date in done { planning[date] = nil }
        if !done.isEmpty { await loadPlans() }
        if let failed = latest.first(where: { $0.status == "failed" }) {
            error = "Couldn't style \(Day.date(failed.date).formatted(.dateTime.weekday(.wide))): \(failed.error ?? "try again.")"
            for entry in latest where entry.status == "failed" {
                let _: [Styling]? = try? await send("/api/import/plans/styling/\(entry.date)", method: "DELETE")
            }
            styling.removeAll { $0.status == "failed" }
        }
    }

    func loadPlans() async {
        await run { plans = try await send("/api/import/plans") }
    }

    func tryOn(_ plan: Plan) async {
        await Notifier.requestPermission()
        // Safe to repeat: the server doesn't start a second try-on of the same day.
        await run { plans = try await send("/api/import/plans/\(plan.date)/try-on", method: "POST", body: [:], retry: true) }
    }

    /// AI work is still running on the Mac (cutouts or try-ons), so a notification is worth waiting for.
    var hasPendingWork: Bool {
        plans.contains { $0.tryOn?.status == "processing" }
            || !uploading.isEmpty || detections.contains(where: \.isWorking)
            || items.contains { $0.back?.status == "processing" || $0.front?.status == "processing" }
            || jobs.contains { ["queued", "processing"].contains($0.current.stage.status) || ($0.current.name == "garment" && $0.current.stage.status == "pending") }
    }

    /// Anything the AI is working on that the user is watching.
    var isWorking: Bool { !planning.isEmpty || !uploading.isEmpty || detections.contains(where: \.isWorking) || styling.contains { $0.status == "working" } || hasPendingWork }

    func loadProgress() async {
        if let latest: [String: String] = try? await send("/api/import/progress") { progress = latest }
    }

    func deletePlan(_ plan: Plan) async {
        await run { plans = try await send("/api/import/plans/\(plan.date)", method: "DELETE") }
    }

    func loadJobs() async {
        await run { jobs = try await send("/api/import/jobs") }
    }

    /// Uploads a photo; the Mac searches it in the background and poll() follows along.
    func importPhoto(_ jpeg: Data) async {
        let id = UUID().uuidString
        uploading.append(id)
        defer { uploading.removeAll { $0 == id } }
        await Notifier.requestPermission()
        // Finishes the upload if the user leaves the app; the rest happens on the Mac.
        let task = UIApplication.shared.beginBackgroundTask(withName: "import")
        defer { UIApplication.shared.endBackgroundTask(task) }
        await run {
            // Safe to repeat: the server joins an upload with the same id to the search already running.
            let detection: Detection = try await send("/api/import/jobs", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "clientId": id, "background": true], retry: true)
            detections.removeAll { $0.id == detection.id }
            detections.append(detection)
        }
    }

    /// action is approve, reject or regenerate.
    func review(_ job: Job, _ action: String) async {
        guard !reviewing.contains(job.id) else { return }
        reviewing.insert(job.id)
        defer { reviewing.remove(job.id) }
        await run {
            // Safe to repeat: the server treats a second approve or discard of the same piece as done.
            let _: AnyCodable = try await send("/api/import/jobs/\(job.id)/stages/\(job.current.name)/\(action)", method: "POST", body: [:], retry: true)
            jobs = try await send("/api/import/jobs")
            if action == "approve", job.current.name != "crop" { items = try await send("/api/import/wardrobe") }
        }
    }
}

/// Decodes any JSON value when only success matters.
nonisolated struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}
