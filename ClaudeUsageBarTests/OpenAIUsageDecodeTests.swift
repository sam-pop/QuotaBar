import Testing
import Foundation

@Suite("OpenAI usage decode")
struct OpenAIUsageDecodeTests {
    /// Trimmed from the design spike's live response (spec §2 O1).
    private let fixture = #"""
    {"user_id":"user-x","account_id":"55f9262b-efec-4c8f-b94f-cfad13ad735b","email":"sam@example.com","plan_type":"team",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":52,"limit_window_seconds":18000,"reset_after_seconds":15891,"reset_at":1788845315},
       "secondary_window":{"used_percent":52.6,"limit_window_seconds":604800,"reset_after_seconds":499180,"reset_at":1789328604}},
     "model_usage":{"gpt-6-astra":{"available":true}},"credits":{"has_credits":false},"rate_limit_reset_credits":{"available_count":2}}
    """#

    @Test("Maps primary → five_hour and secondary → seven_day with epoch resets as ISO-8601")
    func mapsWindows() throws {
        let decoded = try OpenAIUsage.decode(Data(fixture.utf8))
        let response = try OpenAIUsage.usageResponse(from: decoded)
        #expect(response.fiveHour.utilization == 52)
        #expect(response.sevenDay.utilization == 52.6)
        #expect(response.limits == nil)
        // The synthesized ISO strings must round-trip through UsageSnapshot's parser to the
        // exact epoch instants.
        let snapshot = UsageSnapshot(from: response)
        #expect(snapshot.fiveHourPercent == 52)
        #expect(snapshot.sevenDayPercent == 53)
        #expect(snapshot.fiveHourResetsAt == Date(timeIntervalSince1970: 1_788_845_315))
        #expect(snapshot.sevenDayResetsAt == Date(timeIntervalSince1970: 1_789_328_604))
        #expect(snapshot.modelLimits == nil)
    }

    @Test("Identity comes from account_id and email; displayName is nil")
    func identity() throws {
        let identity = OpenAIUsage.identity(from: try OpenAIUsage.decode(Data(fixture.utf8)))
        #expect(identity == AccountIdentity(uuid: "55f9262b-efec-4c8f-b94f-cfad13ad735b", email: "sam@example.com", displayName: nil))
    }

    @Test("A missing secondary window becomes 0% with no reset; a missing primary window is a decode failure")
    func missingWindows() throws {
        let noSecondary = #"{"account_id":"a","rate_limit":{"primary_window":{"used_percent":10,"reset_at":1788845315},"secondary_window":null}}"#
        let response = try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(Data(noSecondary.utf8)))
        #expect(response.sevenDay.utilization == 0)
        #expect(UsageSnapshot(from: response).sevenDayResetsAt == nil)

        let noPrimary = #"{"account_id":"a","rate_limit":{"secondary_window":{"used_percent":10,"reset_at":1}}}"#
        #expect(throws: UsageAPIError.self) {
            try OpenAIUsage.usageResponse(from: try OpenAIUsage.decode(Data(noPrimary.utf8)))
        }
    }

    @Test("A non-JSON body (challenge page) is a decoding error, not a crash")
    func nonJSON() {
        #expect(throws: DecodingError.self) {
            try OpenAIUsage.decode(Data("<html>Just a moment...</html>".utf8))
        }
    }
}
