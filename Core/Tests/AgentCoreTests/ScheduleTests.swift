import XCTest
@testable import AgentCore

final class ScheduleTests: XCTestCase {
    private let shanghai = 8 * 3600

    func testIntervalsNeedNoTimezone() {
        XCTAssertEqual(scheduleString(.minutes(30), zoneOffset: shanghai, hostOffset: 0), "every 30m")
        XCTAssertEqual(scheduleString(.hours(2), zoneOffset: shanghai, hostOffset: 0), "every 2h")
    }

    func testDailyTimeIsMovedToTheHostsZone() {
        // 10:00 in Shanghai is 02:00 on a UTC host: the real "team-ceo-daily-1000-shanghai" job.
        XCTAssertEqual(scheduleString(.daily(hour: 10, minute: 0), zoneOffset: shanghai, hostOffset: 0), "0 2 * * *")
        XCTAssertEqual(scheduleString(.daily(hour: 9, minute: 30), zoneOffset: shanghai, hostOffset: shanghai), "30 9 * * *")
        // Half-hour zones move the minutes too (India, UTC+5:30).
        XCTAssertEqual(scheduleString(.daily(hour: 0, minute: 15), zoneOffset: 19800, hostOffset: 0), "45 18 * * *")
    }

    func testWeeklyDaysShiftWhenTheTimeCrossesMidnight() {
        // Monday 07:00 Shanghai is Sunday 23:00 UTC.
        XCTAssertEqual(scheduleString(.weekly(days: [1], hour: 7, minute: 0), zoneOffset: shanghai, hostOffset: 0), "0 23 * * 0")
        // Sunday wraps back to Saturday.
        XCTAssertEqual(scheduleString(.weekly(days: [0, 3], hour: 1, minute: 5), zoneOffset: shanghai, hostOffset: 0), "5 17 * * 2,6")
        // Host ahead of the user: Saturday 20:00 New York (UTC-5) is Sunday 09:00 Shanghai.
        XCTAssertEqual(scheduleString(.weekly(days: [6], hour: 20, minute: 0), zoneOffset: -5 * 3600, hostOffset: shanghai), "0 9 * * 0")
        XCTAssertEqual(scheduleString(.weekly(days: [0, 1, 2, 3, 4, 5, 6], hour: 10, minute: 0), zoneOffset: shanghai, hostOffset: 0), "0 2 * * *")
    }

    func testRawCronIsPassedThrough() {
        XCTAssertEqual(scheduleString(.cron(" 0 2,6,10 * * * "), zoneOffset: shanghai, hostOffset: 0), "0 2,6,10 * * *")
    }

    func testExistingJobsRoundTripThroughTheForm() {
        let specs: [ScheduleSpec] = [
            .minutes(45), .hours(3), .daily(hour: 10, minute: 0), .daily(hour: 3, minute: 59),
            .weekly(days: [1, 3, 5], hour: 7, minute: 30), .weekly(days: [0], hour: 23, minute: 0), .cron("0 2,6,10 * * *"),
        ]
        for spec in specs {
            for (zone, host) in [(shanghai, 0), (0, 0), (-5 * 3600, shanghai), (19800, -8 * 3600)] {
                let text = scheduleString(spec, zoneOffset: zone, hostOffset: host)
                let kind = text.hasPrefix("every") ? "interval" : "cron"
                var minutes = 0
                if case .minutes(let n) = spec { minutes = n }
                if case .hours(let n) = spec { minutes = n * 60 }
                XCTAssertEqual(scheduleSpec(kind: kind, expr: kind == "cron" ? text : "", minutes: minutes, zoneOffset: zone, hostOffset: host), spec, "\(spec) \(zone) \(host)")
            }
        }
    }

    func testWhatTheBuilderCannotExpressStaysCron() {
        for expr in ["3 * * * *", "0 9 1 * *", "*/5 9 * * *", "0 9 * * MON-FRI", "0 9 * * 1-5", "0 2,6,10 * * *"] {
            XCTAssertEqual(scheduleSpec(kind: "cron", expr: expr, minutes: 0, zoneOffset: shanghai, hostOffset: 0), .cron(expr))
        }
        // Cron allows 7 for Sunday.
        XCTAssertEqual(scheduleSpec(kind: "cron", expr: "0 12 * * 7", minutes: 0, zoneOffset: 0, hostOffset: 0), .weekly(days: [0], hour: 12, minute: 0))
        XCTAssertEqual(scheduleSpec(kind: "once", expr: "", minutes: 0, zoneOffset: 0, hostOffset: 0), .cron(""))
    }

    func testDescriptions() {
        XCTAssertEqual(describeSchedule(.minutes(30)), "Every 30 minutes")
        XCTAssertEqual(describeSchedule(.hours(1)), "Every hour")
        XCTAssertEqual(describeSchedule(.daily(hour: 9, minute: 5)), "Daily at 09:05")
        XCTAssertEqual(describeSchedule(.weekly(days: [1, 2, 3, 4, 5], hour: 9, minute: 0)), "Weekdays at 09:00")
        XCTAssertEqual(describeSchedule(.weekly(days: [0, 3, 1], hour: 18, minute: 30)), "Mon, Wed, Sun at 18:30")
        XCTAssertEqual(describeSchedule(.cron("0 2,6,10 * * *")), "0 2,6,10 * * *")
    }

    func testValidation() {
        XCTAssertTrue(isValidSchedule(.minutes(5)))
        XCTAssertFalse(isValidSchedule(.minutes(0)))
        XCTAssertFalse(isValidSchedule(.weekly(days: [], hour: 9, minute: 0)))
        XCTAssertFalse(isValidSchedule(.daily(hour: 24, minute: 0)))
        XCTAssertTrue(isValidSchedule(.cron("0 9 * * MON-FRI")))
        XCTAssertFalse(isValidSchedule(.cron("0 9 * *")))
        XCTAssertFalse(isValidSchedule(.cron("0 9 * * *; rm -rf /")))
    }

    /// The bridge's reply for jobs listed by a real gateway (hermes-bridge/fixtures).
    func testDecodesTheBridgesJobList() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("hermes-bridge/fixtures/jobs_reply.json"))
        let list = try JSONDecoder().decode(JobList.self, from: data)
        XCTAssertEqual(list.jobs.count, 3)
        let daily = try XCTUnwrap(list.jobs.first { $0.id == "42e312f2c0d4" })
        XCTAssertEqual(daily.next_run, 1_794_621_600)
        XCTAssertTrue(daily.enabled)
        let spec = scheduleSpec(kind: daily.kind, expr: daily.expr, minutes: daily.minutes, zoneOffset: shanghai, hostOffset: list.offsets["default"] ?? 0)
        XCTAssertEqual(describeSchedule(spec), "Daily at 10:00")
        let paused = try XCTUnwrap(list.jobs.first { $0.id == "2606b6b03fc2" })
        XCTAssertEqual([paused.enabled, paused.no_agent], [false, true])
        XCTAssertNil(try XCTUnwrap(list.jobs.first { $0.kind == "interval" }).next_run.flatMap { $0 < 0 ? $0 : nil })
    }

    func testBridgeVersionCheck() {
        XCTAssertTrue(versionIsOlder("0.2.0", than: "0.2.1"))
        XCTAssertFalse(versionIsOlder("0.2.1", than: "0.2.1"))
        XCTAssertFalse(versionIsOlder("0.10.0", than: "0.2.1"))
        XCTAssertTrue(versionIsOlder("", than: "0.2.1"))
    }

    func testBridgeUpgradeCommand() throws {
        XCTAssertEqual(bridgeUpgradeCommand(source: "/home/hermes/agentgram"),
                       "cd /home/hermes/agentgram && git pull --ff-only && sudo hermes-bridge/install.sh")
        XCTAssertEqual(bridgeUpgradeCommand(source: nil), "cd ~/agentgram && git pull --ff-only && sudo hermes-bridge/install.sh")
        XCTAssertEqual(bridgeUpgradeCommand(source: ""), bridgeUpgradeCommand(source: nil))
        XCTAssertTrue(bridgeUpgradeCommand(source: "/srv/my repo/it's").hasPrefix("cd '/srv/my repo/it'\\''s' && "))
        // Bridge 0.2.1 says nothing about its source; 0.3.0 does.
        let old = try JSONDecoder().decode(Hello.self, from: Data(#"{"bridge":"0.2.1","hermes":"v","api":true}"#.utf8))
        XCTAssertNil(old.updatable)
        let new = try JSONDecoder().decode(Hello.self, from: Data(#"{"bridge":"0.3.0","hermes":"v","api":true,"source":"/x","updatable":true}"#.utf8))
        XCTAssertEqual([new.source, new.updatable.map { "\($0)" }], ["/x", "true"])
        let done = try JSONDecoder().decode(BridgeUpdated.self, from: Data(#"{"version":"0.3.1","updated":true}"#.utf8))
        XCTAssertEqual(done.version, "0.3.1")
        XCTAssertTrue(done.updated)
    }

    func testLibraryFilter() {
        let files = [
            HostFile(path: "/h/profiles/team-cro/workspace/report.md", name: "report.md", size: 1, mtime: 3, profile: "team-cro", source: "workspace"),
            HostFile(path: "/h/profiles/team-ceo/workspace/chart.PNG", name: "chart.PNG", size: 1, mtime: 2, profile: "team-ceo", source: "workspace"),
            HostFile(path: "/h/kanban/workspaces/t_1/result.csv", name: "result.csv", size: 1, mtime: 1, profile: "default", source: "board"),
            HostFile(path: "/h/x/Makefile", name: "Makefile", size: 1, mtime: 0, profile: "default", source: "sent"),
        ]
        XCTAssertEqual(files.map { fileKind($0.name) }, [.document, .image, .data, .other])
        XCTAssertEqual(fileKind(".env"), .other)
        XCTAssertEqual(filterFiles(files, query: "", profile: nil, kind: nil), files)
        XCTAssertEqual(filterFiles(files, query: " REPORT ", profile: nil, kind: nil).map(\.name), ["report.md"])
        XCTAssertEqual(filterFiles(files, query: "t_1", profile: nil, kind: nil).map(\.name), ["result.csv"])
        XCTAssertEqual(filterFiles(files, query: "", profile: "default", kind: nil).count, 2)
        XCTAssertEqual(filterFiles(files, query: "", profile: "default", kind: .data).map(\.name), ["result.csv"])
        XCTAssertTrue(filterFiles(files, query: "x", profile: "team-ceo", kind: .code).isEmpty)
    }

    func testReturnKey() {
        // Enter sends; Shift and Option make a new line.
        XCTAssertEqual(returnAction(shift: false, option: false, enterSends: true, composing: false, paletteOpen: false), .send)
        XCTAssertEqual(returnAction(shift: true, option: false, enterSends: true, composing: false, paletteOpen: false), .newline)
        XCTAssertEqual(returnAction(shift: false, option: true, enterSends: true, composing: false, paletteOpen: false), .newline)
        // While the input method is composing (pinyin), Return is never ours.
        for enterSends in [true, false] {
            for palette in [true, false] {
                XCTAssertEqual(returnAction(shift: false, option: false, enterSends: enterSends, composing: true, paletteOpen: palette), .passthrough)
            }
        }
        // An open palette takes Return to pick the highlighted row.
        XCTAssertEqual(returnAction(shift: false, option: false, enterSends: true, composing: false, paletteOpen: true), .complete)
        XCTAssertEqual(returnAction(shift: false, option: false, enterSends: false, composing: false, paletteOpen: true), .complete)
        // "⌘↩ sends" mode: plain Return is a new line.
        XCTAssertEqual(returnAction(shift: false, option: false, enterSends: false, composing: false, paletteOpen: false), .newline)
    }
}
