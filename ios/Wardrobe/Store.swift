import Foundation
import Observation
import UIKit

nonisolated struct Item: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var part: String
    var color: String?
    var secondaryColor: String?
    var tags: [String]?
    var image: String?
    var modeledImage: String?
    var backImage: String?
    var back: Back?
    var unavailable: Bool?
    /// Wears before it needs washing; nil follows the category default.
    var wears: Int?

    var isAvailable: Bool { unavailable != true }
    var wearLimit: Int { wears ?? Parts.defaultWears[part] ?? 1 }

    struct Back: Codable, Hashable { var status: String; var error: String? }
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
    }
}

nonisolated struct Job: Codable, Identifiable, Hashable {
    struct Metadata: Codable, Hashable { var name: String; var part: String }
    struct Stage: Codable, Hashable { var status: String; var assetUrl: String?; var error: String? }
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

struct PlanDay: Hashable { var date: Date; var style: String; var weather = "auto"; var replace: String? = nil }

nonisolated enum Parts {
    static let order = ["upperbody", "midlayer", "wholebody_up", "lowerbody", "shoes", "accessories_up"]
    /// Mirrors DEFAULT_WEARS in scripts/outfit-planner.mjs.
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
    var error: String?
    /// Why the last refresh could not reach the server, shown in the Server sheet.
    var connectionError: String?
    /// The sheet the root view presents (chooser, plan or import).
    var sheet: AppSheet?
    /// Dates the stylist is working on right now.
    var planningDates: Set<String> = []

    // AI calls through Codex or the API can take minutes.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        return URLSession(configuration: configuration)
    }()

    /// The typed address, tolerating a missing scheme and stray whitespace.
    var baseURL: URL? {
        let typed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: typed.contains("://") ? typed : "http://\(typed)")
    }

    func url(_ path: String?) -> URL? {
        guard let path else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let url = url(path) else { throw ServerError(message: "Invalid server address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ServerError(message: message ?? "Server error \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Runs an action and surfaces failures as an alert instead of throwing.
    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch is CancellationError {} catch let error as URLError where error.code == .cancelled {} catch {
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
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            print("Wardrobe could not reach \(serverURL): \(error)")
            config = nil
            connectionError = error.localizedDescription
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
            var body: [String: Any] = ["name": item.name, "part": item.part, "tags": item.tags ?? []]
            body["color"] = item.color
            body["secondaryColor"] = item.secondaryColor ?? NSNull()
            body["wears"] = item.wears ?? NSNull()
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)", method: "PATCH", body: body)
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
        }
    }

    func addBack(_ item: Item, jpeg: Data) async {
        await Notifier.requestPermission()
        await run {
            let saved: Item = try await send("/api/import/wardrobe/\(item.id)/back", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
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

    func generate(_ days: [PlanDay]) async {
        let dates = Set(days.map { Day.string($0.date) })
        planningDates.formUnion(dates)
        defer { planningDates.subtract(dates) }
        await run {
            let body = days.map { day in
                var entry = ["date": Day.string(day.date), "style": day.style, "weather": day.weather]
                entry["replace"] = day.replace
                return entry
            }
            plans = try await send("/api/import/plans", method: "POST", body: ["days": body])
        }
    }

    func loadPlans() async {
        await run { plans = try await send("/api/import/plans") }
    }

    func tryOn(_ plan: Plan) async {
        await Notifier.requestPermission()
        await run { plans = try await send("/api/import/plans/\(plan.date)/try-on", method: "POST", body: [:]) }
    }

    /// AI work is still running on the Mac (cutouts or try-ons), so a notification is worth waiting for.
    var hasPendingWork: Bool {
        plans.contains { $0.tryOn?.status == "processing" }
            || items.contains { $0.back?.status == "processing" }
            || jobs.contains { ["queued", "processing"].contains($0.current.stage.status) || ($0.current.name == "garment" && $0.current.stage.status == "pending") }
    }

    func deletePlan(_ plan: Plan) async {
        await run { plans = try await send("/api/import/plans/\(plan.date)", method: "DELETE") }
    }

    func loadJobs() async {
        await run { jobs = try await send("/api/import/jobs") }
    }

    func importPhoto(_ jpeg: Data) async {
        await Notifier.requestPermission()
        // Finding clothes takes a few seconds; keep running if the user leaves and tell them when it's done.
        let task = UIApplication.shared.beginBackgroundTask(withName: "import")
        defer { UIApplication.shared.endBackgroundTask(task) }
        await run {
            let found: ImportResult = try await send("/api/import/jobs", method: "POST", body: ["imageDataUrl": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
            if UIApplication.shared.applicationState != .active, !found.jobs.isEmpty {
                Notifier.post("Ready to review", found.jobs.count == 1 ? "Found 1 piece in your photo." : "Found \(found.jobs.count) pieces in your photo.")
            }
            jobs = try await send("/api/import/jobs")
        }
    }

    /// action is approve, reject or regenerate.
    func review(_ job: Job, _ action: String) async {
        await run {
            let _: Job = try await send("/api/import/jobs/\(job.id)/stages/\(job.current.name)/\(action)", method: "POST", body: [:])
            jobs = try await send("/api/import/jobs")
            if action == "approve", job.current.name != "crop" { items = try await send("/api/import/wardrobe") }
        }
    }
}

nonisolated struct ImportResult: Decodable { let jobs: [Job] }

/// Decodes any JSON value when only success matters.
nonisolated struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}
