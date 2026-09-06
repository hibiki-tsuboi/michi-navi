import Combine
import CoreLocation
import Testing
@testable import MichiNavi

@MainActor
struct SightseeingAdvisorTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func location(_ time: Date, north: Double = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 35 + north / 111_320, longitude: 139),
                   altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                   course: 0, courseAccuracy: 5, speed: 10, speedAccuracy: 1, timestamp: time)
    }

    private var spot: SightseeingSpot {
        SightseeingSpot(id: "shrine", name: "試験神社",
                        coordinate: CLLocationCoordinate2D(latitude: 35.001, longitude: 139.001), detail: nil)
    }

    private func update(_ advisor: SightseeingAdvisor, at time: Date, north: Double = 0) {
        advisor.update(location(time, north: north), now: time, hasActiveRoute: false, progress: nil, isRerouting: false)
    }

    @Test("CarPlay接続と設定が有効なときだけ検索し、切った設定を保存する")
    func connectionAndSettingGateSearch() async throws {
        let suite = "SightseeingAdvisorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let advisor = SightseeingAdvisor(defaults: defaults) { _ in calls += 1; return [] }
        update(advisor, at: now)
        #expect(advisor.searchTask == nil)
        advisor.setConnected(true)
        update(advisor, at: now)
        await advisor.searchTask?.value
        #expect(calls == 1)
        advisor.isEnabled = false
        update(advisor, at: now.addingTimeInterval(100))
        #expect(advisor.searchTask == nil)
        #expect(!SightseeingAdvisor(defaults: defaults).isEnabled)
        advisor.isEnabled = true
        advisor.setConnected(false)
        update(advisor, at: now.addingTimeInterval(200))
        #expect(advisor.searchTask == nil)
    }

    @Test("Dashboardだけの接続でも動き、一つの画面が閉じても他が残れば止まらない")
    func tracksAllCarPlayScenes() throws {
        let suite = "SightseeingAdvisorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let advisor = SightseeingAdvisor(defaults: defaults)
        advisor.setConnected(true, sceneID: "dashboard")
        #expect(advisor.isConnected)
        advisor.setConnected(true, sceneID: "main")
        advisor.setConnected(false, sceneID: "dashboard")
        #expect(advisor.isConnected)
        advisor.setConnected(false, sceneID: "main")
        #expect(!advisor.isConnected)
    }

    @Test("検索結果をキャッシュし、通信中に通過した施設は後追いしない")
    func evaluatesAtLatestLocation() async throws {
        let suite = "SightseeingAdvisorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let advisor = SightseeingAdvisor(defaults: defaults) { _ in calls += 1; return [spot] }
        advisor.setConnected(true)
        var notices: [SightseeingGuide.Notice] = []
        let subscription = advisor.notice.sink { notices.append($0) }
        defer { subscription.cancel() }
        update(advisor, at: now)
        await advisor.searchTask?.value
        #expect(notices.isEmpty)
        update(advisor, at: now.addingTimeInterval(5), north: 250)
        #expect(notices.isEmpty)
        update(advisor, at: now.addingTimeInterval(10))
        #expect(notices.count == 1)
        update(advisor, at: now.addingTimeInterval(61))
        await advisor.searchTask?.value
        #expect(calls == 1)
        update(advisor, at: now.addingTimeInterval(100), north: 900)
        await advisor.searchTask?.value
        #expect(calls == 2)
    }

    @Test("圏外で失敗しても問い合わせを連打せず、後で再試行する")
    func retriesAfterFailure() async throws {
        enum Offline: Error { case unavailable }
        let suite = "SightseeingAdvisorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let advisor = SightseeingAdvisor(defaults: defaults) { _ in calls += 1; throw Offline.unavailable }
        advisor.setConnected(true)
        update(advisor, at: now)
        await advisor.searchTask?.value
        update(advisor, at: now.addingTimeInterval(5), north: 1000)
        #expect(advisor.searchTask == nil)
        update(advisor, at: now.addingTimeInterval(65), north: 1000)
        await advisor.searchTask?.value
        #expect(calls == 2)
    }

    @Test("切断前の検索が後から完了しても、再接続後の結果を上書きしない")
    func cancelledSearchCannotReplaceNewResults() async throws {
        let suite = "SightseeingAdvisorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var finishOld: CheckedContinuation<[SightseeingSpot], Never>?
        var began: CheckedContinuation<Void, Never>?
        var calls = 0
        let advisor = SightseeingAdvisor(defaults: defaults) { _ in
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { continuation in
                    finishOld = continuation
                    began?.resume()
                }
            }
            return [spot]
        }
        advisor.setConnected(true)
        update(advisor, at: now)
        let oldTask = advisor.searchTask
        await withCheckedContinuation {
            if finishOld != nil { $0.resume() } else { began = $0 }
        }
        advisor.setConnected(false)
        advisor.setConnected(true)
        update(advisor, at: now.addingTimeInterval(1))
        await advisor.searchTask?.value
        finishOld?.resume(returning: [])
        await oldTask?.value
        var notices: [SightseeingGuide.Notice] = []
        let subscription = advisor.notice.sink { notices.append($0) }
        defer { subscription.cancel() }
        update(advisor, at: now.addingTimeInterval(2))
        #expect(notices.first?.spot.id == "shrine")
    }
}
