import Foundation
import Network
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
    /// Exact printed or embroidered text on the front, with placement; empty when there is none.
    var text: String?
    /// The same for the back, filled in when a back photo is added.
    var backText: String?
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
    var palette: String?
    /// A piece the outfit was built around.
    var include: String?
    var note: String?
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

struct PlanDay: Hashable {
    var date: Date
    var style: String
    var weather = "auto"
    var palette = "any"
    var include: String? = nil
    var note = ""
    var replace: String? = nil
}

extension PlanDay {
    /// Restyles a planned day with the same choices; replace swaps just that piece.
    init(_ plan: Plan, replace: String? = nil) {
        self.init(date: Day.date(plan.date), style: plan.style, weather: plan.weather ?? "auto", palette: plan.palette ?? "any",
                  include: replace == nil ? plan.include : nil, note: plan.note ?? "", replace: replace)
    }
}

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
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
            // Another address is another server: nothing known about the old one counts until it answers.
            config = nil
            refreshing = nil
        }
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
    static let minimumServerAPI = 6
    var serverIsOutdated: Bool { config != nil && (version?.api ?? 0) < Self.minimumServerAPI }
    var error: String?
    /// Open sheets; while one is up, it shows errors itself, because an alert on the root view would close it.
    var sheetDepth = 0
    /// Why the last refresh could not reach the server, shown in the Server sheet.
    var connectionError: String?
    /// False as soon as a request or the heartbeat can't reach the Mac, so actions fail at once instead of after a timeout.
    var isOnline = true
    var isConnected: Bool { isOnline && config != nil }
    private static let offlineMessage = "Couldn't reach your Mac. Check that it's awake and on the same Wi-Fi, then try again."
    private let pathMonitor = NWPathMonitor()

    init() {
        // Wi-Fi coming or going is checked right away rather than at the next heartbeat.
        pathMonitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in await self?.checkConnection() } }
        pathMonitor.start(queue: .main)
    }
    /// The sheet the root view presents (chooser, plan or import).
    var sheet: AppSheet?
    /// Days the stylist is working on right now, by date; their weather shapes the loading skeleton.
    var planning: [String: PlanDay] = [:]
    var planningDates: Set<String> { Set(planning.keys).union(styling.filter { $0.status == "working" }.map(\.date)) }
    var styling: [Styling] = []
    /// Days whose styling request is still on its way, so a status check that beats it to the Mac doesn't drop them.
    private var startingPlans: Set<String> = []
    /// Photos still uploading, then searched on the Mac.
    var uploading: [String] = []
    var detections: [Detection] = []
    /// Import jobs with a review action in flight, so their buttons can't be tapped twice.
    var reviewing: Set<String> = []
    /// What the AI is doing right now ("Checking the cutout…", "Retrying (2/3): …"), keyed like "job:<id>" or "plan:<date>".
    var progress: [String: String] = [:]
    /// Edits that couldn't be saved yet, kept across launches and sent again once the Mac answers.
    private(set) var pendingEdits: [String: Item] = UserDefaults.standard.data(forKey: "pendingEdits").flatMap { try? JSONDecoder().decode([String: Item].self, from: $0) } ?? [:] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pendingEdits), forKey: "pendingEdits") }
    }
    /// The user's outline for the try-on skeleton, made once per photo of them because Vision takes a moment.
    @ObservationIgnored var silhouette: (stamp: Date, image: CGImage)?
    /// How far the Mac's clock is ahead of the phone's, from its replies, so wait cursors use the Mac's time.
    @ObservationIgnored private(set) var serverClockOffset: TimeInterval = 0
    /// Bumped whenever a change on the server succeeds, so a list read that started before it can't put old values back.
    @ObservationIgnored private var changes = 0
    /// Counts settings saves, so only the newest reply is shown when taps outrun the Mac.
    @ObservationIgnored private var settingsWrites = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var sendingPending = false
    /// Photos not yet on the Mac, kept on disk so a sleeping Mac or a closed app loses none; sent again on reconnect.
    private static let outbox = URL.applicationSupportDirectory.appending(path: "outbox", directoryHint: .isDirectory)
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

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
        // The server only accepts changes sent as JSON, even ones without a body.
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
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
        if method != "GET" { changes += 1 }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A list endpoint, skipping any entry this app can't read instead of failing the whole list.
    private func sendList<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, retry: Bool? = nil) async throws -> [T] {
        let list: Lossy<T> = try await send(path, method: method, body: body, retry: retry)
        return list.elements
    }

    /// Runs an action and surfaces failures as an alert instead of throwing.
    private func run(_ action: () async throws -> Void) async {
        if !isOnline { await checkConnection() }
        guard isOnline else { error = Self.offlineMessage; return }
        do { try await action() } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch let error as URLError where Self.transient.contains(error.code) {
            print("Wardrobe request failed: \(error)")
            isOnline = false
            self.error = Self.offlineMessage
        } catch {
            print("Wardrobe request failed: \(error)")
            self.error = error.localizedDescription
        }
    }

    /// Reloads everything; calls that overlap (launch, foregrounding, the heartbeat) share one round of requests.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await reload(); refreshing = nil }
        refreshing = task
        await task.value
    }

    private func reload() async {
        let started = changes
        do {
            async let loadedItems: [Item] = sendList("/api/import/wardrobe")
            async let loadedPlans: [Plan] = sendList("/api/import/plans")
            async let loadedConfig: ServerConfig = send("/api/import/config")
            async let loadedJobs: [Job] = sendList("/api/import/jobs")
            let (latestItems, latestPlans, latestConfig, latestJobs) = try await (loadedItems, loadedPlans, loadedConfig, loadedJobs)
            config = latestConfig
            // A change that finished meanwhile already brought newer lists.
            if started == changes { (items, plans, jobs) = (latestItems, latestPlans, latestJobs) }
            connectionError = nil
            isOnline = true
            // Older servers lack these (that is what serverIsOutdated reports); a dropped request keeps what was known.
            do { version = try await send("/api/import/version") } catch is URLError, is CancellationError {} catch { version = nil }
            do { settings = try await send("/api/import/settings") } catch is URLError, is CancellationError {} catch { settings = nil }
            // Searches and styling may have finished, or still be running, from before the app was closed.
            await loadDetections()
            await loadStyling()
            // Not part of this refresh: an action in it that finds the Mac gone refreshes, and would wait on itself.
            Task { await sendPending() }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch let error as URLError {
            print("Wardrobe could not reach \(serverURL): \(error)")
            isOnline = false
            connectionError = error.localizedDescription
        } catch {
            // The Mac answered with something this app couldn't read: it is reachable, so actions shouldn't say otherwise.
            print("Wardrobe could not read \(serverURL): \(error)")
            isOnline = true
            connectionError = error.localizedDescription
        }
    }

    /// Sends what couldn't reach the Mac before: edits made while it was away, and photos still waiting to upload.
    private func sendPending() async {
        guard !sendingPending else { return }
        sendingPending = true
        defer { sendingPending = false }
        for edit in pendingEdits.values { await update(edit) }
        let waiting = (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []
        for file in waiting {
            let id = file.deletingPathExtension().lastPathComponent
            guard !uploading.contains(id), let jpeg = try? Data(contentsOf: file) else { continue }
            await importPhoto(jpeg, id: id)
        }
    }

    /// A short look at whether the Mac answers; everything is reloaded when it comes back.
    func checkConnection() async {
        guard let url = url("/api/import/version") else { return }
        do {
            let (_, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            if let date = http.value(forHTTPHeaderField: "Date").flatMap({ Self.httpDate.date(from: $0) }) { serverClockOffset = date.timeIntervalSinceNow }
            if !isOnline || config == nil { await refresh() }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            isOnline = false
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
        let previous = settings
        settings?.wears?[part] = wears
        await saveSettings(["wears": [part: wears]], previous: previous)
    }

    func setChecks(_ checks: String) async {
        await saveSettings(["checks": checks], previous: settings)
    }

    private func saveSettings(_ body: [String: Any], previous: ServerSettings?) async {
        settingsWrites += 1
        let write = settingsWrites
        var saved = false
        await run {
            let latest: ServerSettings = try await send("/api/import/settings", method: "PATCH", body: body)
            saved = true
            if write == settingsWrites { settings = latest }
        }
        // A save that didn't land shows what the Mac has, not a value it never stored.
        if !saved, write == settingsWrites {
            let latest: ServerSettings? = try? await send("/api/import/settings")
            settings = latest ?? previous
        }
    }

    func uploadModelReference(_ jpeg: Data) async {
        await run {
            config = try await send("/api/import/model-reference", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
            referenceStamp = .now
        }
    }

    func setUnavailable(_ ids: [String], _ unavailable: Bool) async {
        await run { items = try await sendList("/api/import/wardrobe", method: "PATCH", body: ["ids": ids, "unavailable": unavailable]) }
    }

    func loadItems() async {
        let started = changes
        if let latest: [Item] = try? await sendList("/api/import/wardrobe"), started == changes { items = latest }
    }

    /// Saves edited details; the server normalizes them and returns the stored piece.
    /// Kept as pending until the Mac has them, so an edit made while it's away isn't lost.
    func update(_ item: Item) async {
        pendingEdits[item.id] = item
        await run {
            var body: [String: Any] = ["name": item.name, "part": item.part, "tags": item.tags ?? [], "description": item.description ?? "", "text": item.text ?? "", "backText": item.backText ?? ""]
            body["color"] = item.color
            body["secondaryColor"] = item.secondaryColor ?? NSNull()
            body["wears"] = item.wears ?? NSNull()
            let saved: Item
            do { saved = try await send("/api/import/wardrobe/\(item.id)", method: "PATCH", body: body) } catch let error where !(error is URLError) {
                // The Mac turned it down (the piece is gone, say); sending it again won't help.
                pendingEdits[item.id] = nil
                throw error
            }
            pendingEdits[item.id] = nil
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
            pendingEdits[item.id] = nil
        }
    }

    /// Starts styling on the Mac; poll() picks up the result, so leaving the app or losing Wi-Fi meanwhile loses nothing.
    func generate(_ days: [PlanDay]) async {
        let dates = days.map { Day.string($0.date) }
        for day in days { planning[Day.string(day.date)] = day }
        startingPlans.formUnion(dates)
        defer { startingPlans.subtract(dates) }
        await run {
            let body = days.map { day in
                var entry = ["date": Day.string(day.date), "style": day.style, "weather": day.weather, "palette": day.palette, "note": day.note]
                entry["replace"] = day.replace
                entry["include"] = day.include
                return entry
            }
            styling = try await sendList("/api/import/plans", method: "POST", body: ["days": body, "background": true])
        }
        // Not started at all: nothing to wait for.
        for date in dates where !styling.contains(where: { $0.date == date && $0.status == "working" }) { planning[date] = nil }
    }

    /// One round of status checks while the AI works: live messages, photos being searched, days being styled.
    func poll() async {
        await loadProgress()
        if !detections.isEmpty || !uploading.isEmpty { await loadDetections() }
        if !planning.isEmpty || !styling.isEmpty { await loadStyling() }
        // Results land in these lists, so they're reloaded while their work runs, whichever screen is open.
        if itemsWorking { await loadItems() }
        if jobsWorking { await loadJobs() }
        if tryOnsWorking { await loadPlans() }
    }

    func loadDetections() async {
        let started = changes
        guard let latest: [Detection] = try? await sendList("/api/import/detections"), started == changes else { return }
        let finished = detections.filter(\.isWorking).contains { old in latest.first { $0.id == old.id }?.isWorking != true }
        detections = latest
        if finished { await loadJobs() }
    }

    func dismissDetection(_ detection: Detection) async {
        detections.removeAll { $0.id == detection.id }
        await run { detections = try await sendList("/api/import/detections/\(detection.id)", method: "DELETE") }
    }

    func loadStyling() async {
        let started = changes
        guard let latest: [Styling] = try? await sendList("/api/import/plans/styling"), started == changes else { return }
        let before = planningDates
        styling = latest
        let working = Set(latest.filter { $0.status == "working" }.map(\.date))
        for date in planning.keys where !working.contains(date) && !startingPlans.contains(date) { planning[date] = nil }
        // Any day that stopped being styled has a new outfit (or failed); either way the plans changed.
        if !before.subtracting(planningDates).isEmpty { await loadPlans() }
        if let failed = latest.first(where: { $0.status == "failed" }) {
            error = "Couldn't style \(Day.date(failed.date).formatted(.dateTime.weekday(.wide))): \(failed.error ?? "try again.")"
            for entry in latest where entry.status == "failed" {
                let _: [Styling]? = try? await send("/api/import/plans/styling/\(entry.date)", method: "DELETE")
            }
            styling.removeAll { $0.status == "failed" }
        }
    }

    func loadPlans() async {
        let started = changes
        if let latest: [Plan] = try? await sendList("/api/import/plans"), started == changes { plans = latest }
    }

    func tryOn(_ plan: Plan) async {
        await Notifier.requestPermission()
        // Safe to repeat: the server doesn't start a second try-on of the same day.
        await run { plans = try await sendList("/api/import/plans/\(plan.date)/try-on", method: "POST", retry: true) }
    }

    private var tryOnsWorking: Bool { plans.contains { $0.tryOn?.status == "processing" } }
    private var itemsWorking: Bool { items.contains { $0.back?.status == "processing" || $0.front?.status == "processing" } }
    private var jobsWorking: Bool {
        jobs.contains { ["queued", "processing"].contains($0.current.stage.status) || ($0.current.name == "garment" && $0.current.stage.status == "pending") }
    }

    /// AI work is still running on the Mac (cutouts or try-ons), so a notification is worth waiting for.
    var hasPendingWork: Bool {
        tryOnsWorking || !uploading.isEmpty || detections.contains(where: \.isWorking) || itemsWorking || jobsWorking
    }

    /// Pieces waiting for the user's decision, counted like the Mac counts them for its notification.
    var reviewCount: Int {
        jobs.filter { $0.current.name != "modeled" && ["review", "failed"].contains($0.current.stage.status) }.count
    }

    /// Anything the AI is working on that the user is watching.
    var isWorking: Bool { !planning.isEmpty || !uploading.isEmpty || detections.contains(where: \.isWorking) || styling.contains { $0.status == "working" } || hasPendingWork }

    func loadProgress() async {
        if let latest: [String: String] = try? await send("/api/import/progress") { progress = latest }
    }

    func deletePlan(_ plan: Plan) async {
        await run { plans = try await sendList("/api/import/plans/\(plan.date)", method: "DELETE") }
    }

    func loadJobs() async {
        let started = changes
        if let latest: [Job] = try? await sendList("/api/import/jobs"), started == changes { jobs = latest }
    }

    /// Uploads a photo; the Mac searches it in the background and poll() follows along.
    /// The photo waits in the outbox until the Mac has it; id stays the same when it's sent again.
    func importPhoto(_ jpeg: Data, id: String = UUID().uuidString) async {
        let file = Self.outbox.appending(path: "\(id).jpg")
        try? FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
        try? jpeg.write(to: file, options: .atomic)
        uploading.append(id)
        defer { uploading.removeAll { $0 == id } }
        await Notifier.requestPermission()
        // Finishes the upload if the user leaves the app; the rest happens on the Mac.
        await withBackgroundTime("import") {
            await run {
                let detection: Detection
                do {
                    // Safe to repeat: the server joins an upload with the same id to the search already running.
                    detection = try await send("/api/import/jobs", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "clientId": id, "background": true], retry: true)
                } catch let error where !(error is URLError) {
                    // The Mac turned the photo down; sending it again won't help.
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
                try? FileManager.default.removeItem(at: file)
                detections.removeAll { $0.id == detection.id }
                detections.append(detection)
            }
        }
    }

    /// action is approve, reject or regenerate.
    func review(_ job: Job, _ action: String) async {
        guard !reviewing.contains(job.id) else { return }
        reviewing.insert(job.id)
        defer { reviewing.remove(job.id) }
        await run {
            // Safe to repeat: the server treats a second approve or discard of the same piece as done.
            let _: AnyCodable = try await send("/api/import/jobs/\(job.id)/stages/\(job.current.name)/\(action)", method: "POST", retry: true)
            jobs = try await sendList("/api/import/jobs")
            if action == "approve", job.current.name != "crop" { items = try await sendList("/api/import/wardrobe") }
        }
    }
}

/// Keeps the app running briefly once it's in the background; when iOS's time is up the task ends instead of the app being killed.
func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
    nonisolated(unsafe) var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: name) {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    await work()
    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
}

/// A list that skips entries it can't read, so one odd record doesn't hide everything else.
nonisolated struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { elements.append(element) } else { _ = try container.decode(AnyCodable.self) }
        }
    }
}

/// Decodes any JSON value when only success matters.
nonisolated struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}
