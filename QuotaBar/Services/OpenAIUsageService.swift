import Foundation

/// The subset of `GET https://chatgpt.com/backend-api/wham/usage` the app consumes
/// (spec §2 O1). Everything else in the payload — credits, model availability, plan — is
/// ignored.
struct OpenAIUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        /// Unix epoch seconds.
        let resetAt: Double?
        /// The window's length in seconds (the spike saw 18000 for 5 hours, 604800 for 7 days).
        let limitWindowSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }
    let accountID: String
    let email: String?
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case email
        case rateLimit = "rate_limit"
    }
}

/// Pure decode + mapping for the OpenAI usage endpoint, kept apart from the networking so
/// it is unit-testable against the spike fixture.
enum OpenAIUsage {
    static func decode(_ data: Data) throws -> OpenAIUsageResponse {
        try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
    }

    /// Synthesizes the Anthropic-shaped `UsageResponse` the runtime already consumes.
    /// Formatting the epoch as an ISO-8601 string that `UsageSnapshot` immediately re-parses
    /// is deliberate — three lines here versus changing the fetch seam and every test that
    /// stubs it.
    ///
    /// When exactly one window is longer than a day it is `seven_day` and the other, if any,
    /// is `five_hour` — so a weekly-only plan has no 5-hour window. Otherwise the windows map
    /// by position as the spike observed: primary → `five_hour`, secondary → `seven_day`. A
    /// missing 7-day window (not observed live; defensive) reads as 0% with no reset; no
    /// window at all is a decode failure.
    static func usageResponse(from response: OpenAIUsageResponse) throws -> UsageResponse {
        let primary = response.rateLimit?.primaryWindow
        let secondary = response.rateLimit?.secondaryWindow
        let windows = [primary, secondary].compactMap { $0 }
        guard !windows.isEmpty else {
            throw UsageAPIError.decodingFailed(MissingWindow())
        }
        let isWeekly = { (window: OpenAIUsageResponse.Window) in (window.limitWindowSeconds ?? 0) > 86_400 }
        let weekly = windows.filter(isWeekly)
        let (fiveHour, sevenDay) = weekly.count == 1
            ? (windows.first { !isWeekly($0) }, weekly.first)
            : (primary, secondary)
        return UsageResponse(
            fiveHour: fiveHour.map { UsagePeriod(utilization: $0.usedPercent, resetsAt: iso8601($0.resetAt)) },
            sevenDay: UsagePeriod(utilization: sevenDay?.usedPercent ?? 0, resetsAt: iso8601(sevenDay?.resetAt)),
            limits: nil)
    }

    static func identity(from response: OpenAIUsageResponse) -> AccountIdentity {
        AccountIdentity(uuid: response.accountID, email: response.email, displayName: nil)
    }

    private struct MissingWindow: LocalizedError {
        var errorDescription: String? { "Usage response had no usage window" }
    }

    /// `""` for a missing epoch: `UsageSnapshot`'s parser turns it into a nil reset date.
    private static func iso8601(_ epoch: Double?) -> String {
        guard let epoch else { return "" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
    }
}

/// Networking for the OpenAI usage endpoint. One GET serves both usage and identity
/// (spec §5.6): the payload carries the account id and email alongside the windows.
/// Mirrors `UsageAPIService`'s request shape and reuses `UsageAPIError`.
enum OpenAIUsageService {
    static func fetch(token: String) async throws -> UsageResponse {
        let data = try await fetchRaw(token: token)
        do {
            return try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(data))
        } catch let error as UsageAPIError {
            throw error
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }

    static func fetchIdentity(token: String) async throws -> AccountIdentity {
        let data = try await fetchRaw(token: token)
        do {
            return OpenAIUsage.identity(from: try OpenAIUsage.decode(data))
        } catch {
            throw UsageAPIError.decodingFailed(error)
        }
    }

    private static func fetchRaw(token: String) async throws -> Data {
        var request = URLRequest(url: OpenAIOAuthEndpoints.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "user-agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageAPIError.requestFailed(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.requestFailed(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            throw UsageAPIError.invalidResponse(http.statusCode)
        }
        return data
    }
}
