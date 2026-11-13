import Foundation

// MARK: - Envelopes (bridge ops jobs.*)

/// One Hermes cron job as the bridge reports it. Times are Unix seconds.
public struct CronJob: Decodable, Equatable, Identifiable {
    public var id: String
    public var profile: String
    public var name: String
    public var prompt: String
    public var kind: String // cron | interval | once
    public var expr: String // cron expression, in the host's timezone
    public var minutes: Int // interval length
    public var display: String
    public var enabled: Bool
    public var state: String // scheduled | paused | running | completed …
    public var next_run: Double?
    public var last_run: Double?
    public var last_status: String
    public var last_error: String
    public var deliver: String
    public var script: String
    public var no_agent: Bool
}

public struct JobList: Decodable {
    public var jobs: [CronJob]
    public var errors: [String]
    /// Per profile: seconds east of UTC of the zone Hermes evaluates cron expressions in.
    public var offsets: [String: Int]
}

public struct JobOutput: Decodable {
    public var file: String
    public var ts: Double?
    public var text: String
}

// MARK: - Schedule builder

/// What the schedule form edits. Clock times are in the timezone the user picked; weekdays are
/// cron's (0 = Sunday … 6 = Saturday).
public enum ScheduleSpec: Equatable {
    case minutes(Int)
    case hours(Int)
    case daily(hour: Int, minute: Int)
    case weekly(days: Set<Int>, hour: Int, minute: Int)
    case cron(String)
}

/// Moves a wall-clock time by `byMinutes`, carrying into the weekdays when it crosses midnight.
public func shiftClock(hour: Int, minute: Int, days: Set<Int>, byMinutes: Int) -> (hour: Int, minute: Int, days: Set<Int>) {
    let total = hour * 60 + minute + byMinutes
    let dayShift = Int((Double(total) / 1440).rounded(.down))
    let clock = total - dayShift * 1440
    return (clock / 60, clock % 60, Set(days.map { (($0 + dayShift) % 7 + 7) % 7 }))
}

/// Five fields of the characters cron uses; Hermes (croniter) does the real validation.
public func isValidCron(_ expr: String) -> Bool {
    let fields = expr.split(separator: " ", omittingEmptySubsequences: true)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*,/-")
    return fields.count == 5 && fields.allSatisfy { $0.unicodeScalars.allSatisfy(allowed.contains) }
}

public func isValidSchedule(_ spec: ScheduleSpec) -> Bool {
    switch spec {
    case .minutes(let n): return (1...10080).contains(n)
    case .hours(let n): return (1...168).contains(n)
    case .daily(let hour, let minute): return (0..<24).contains(hour) && (0..<60).contains(minute)
    case .weekly(let days, let hour, let minute):
        return !days.isEmpty && days.allSatisfy((0...6).contains) && (0..<24).contains(hour) && (0..<60).contains(minute)
    case .cron(let expr): return isValidCron(expr)
    }
}

/// The schedule string Hermes takes (`every 30m`, `0 1 * * *`). Hermes evaluates cron
/// expressions in the host's zone, so clock times are moved from the user's zone to it.
/// Offsets are seconds east of UTC. A raw cron expression is passed through untouched.
// shortcut: the offsets are today's, so a zone with daylight saving drifts an hour at the
// switch until the job is saved again; Asia/Shanghai and UTC have none.
public func scheduleString(_ spec: ScheduleSpec, zoneOffset: Int, hostOffset: Int) -> String {
    let delta = (hostOffset - zoneOffset) / 60
    switch spec {
    case .minutes(let n): return "every \(n)m"
    case .hours(let n): return "every \(n)h"
    case .daily(let hour, let minute):
        let t = shiftClock(hour: hour, minute: minute, days: [], byMinutes: delta)
        return "\(t.minute) \(t.hour) * * *"
    case .weekly(let days, let hour, let minute):
        let t = shiftClock(hour: hour, minute: minute, days: days, byMinutes: delta)
        if t.days.count == 7 { return "\(t.minute) \(t.hour) * * *" }
        return "\(t.minute) \(t.hour) * * \(t.days.sorted().map(String.init).joined(separator: ","))"
    case .cron(let expr): return expr.trimmingCharacters(in: .whitespaces)
    }
}

/// The reverse: what the form shows for an existing job. Anything the builder cannot express
/// (ranges, steps, day-of-month) stays a raw cron expression in the host's zone.
public func scheduleSpec(kind: String, expr: String, minutes: Int, zoneOffset: Int, hostOffset: Int) -> ScheduleSpec {
    if kind == "interval", minutes > 0 {
        return minutes % 60 == 0 ? .hours(minutes / 60) : .minutes(minutes)
    }
    let fields = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard kind == "cron", fields.count == 5, fields[2] == "*", fields[3] == "*",
          let minute = Int(fields[0]), let hour = Int(fields[1]),
          (0..<60).contains(minute), (0..<24).contains(hour) else { return .cron(expr) }
    let delta = (zoneOffset - hostOffset) / 60
    if fields[4] == "*" {
        let t = shiftClock(hour: hour, minute: minute, days: [], byMinutes: delta)
        return .daily(hour: t.hour, minute: t.minute)
    }
    let days = fields[4].split(separator: ",").map { Int($0) }
    guard !days.isEmpty, days.allSatisfy({ $0 != nil && (0...7).contains($0!) }) else { return .cron(expr) }
    let t = shiftClock(hour: hour, minute: minute, days: Set(days.map { $0! % 7 }), byMinutes: delta)
    return .weekly(days: t.days, hour: t.hour, minute: t.minute)
}

private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private func clock(_ hour: Int, _ minute: Int) -> String {
    (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
}

/// "Every 30 minutes", "Daily at 09:00", "Mon, Wed at 09:00"; a raw expression is shown as is.
public func describeSchedule(_ spec: ScheduleSpec) -> String {
    switch spec {
    case .minutes(let n): return n == 1 ? "Every minute" : "Every \(n) minutes"
    case .hours(let n): return n == 1 ? "Every hour" : "Every \(n) hours"
    case .daily(let hour, let minute): return "Daily at \(clock(hour, minute))"
    case .weekly(let days, let hour, let minute):
        let names: String
        switch days {
        case [1, 2, 3, 4, 5]: names = "Weekdays"
        case [0, 6]: names = "Weekends"
        case [0, 1, 2, 3, 4, 5, 6]: names = "Daily"
        default:
            // Monday first, the way the form lists them.
            names = days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { weekdayNames[$0 % 7] }.joined(separator: ", ")
        }
        return "\(names) at \(clock(hour, minute))"
    case .cron(let expr): return expr
    }
}

/// "0.2.0" < "0.2.1": is the bridge on the host older than what this app needs?
public func versionIsOlder(_ version: String, than required: String) -> Bool {
    let a = version.split(separator: ".").map { Int($0) ?? 0 }
    let b = required.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x < y }
    }
    return false
}

// MARK: - Library

public enum FileKind: String, CaseIterable, Identifiable {
    case document = "Documents", image = "Images", code = "Code", data = "Data", other = "Other"
    public var id: String { rawValue }
}

public func fileKind(_ name: String) -> FileKind {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
    switch name[name.index(after: dot)...].lowercased() {
    case "md", "txt", "pdf", "doc", "docx", "rtf", "html", "htm", "ppt", "pptx", "log": return .document
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff": return .image
    case "py", "swift", "js", "ts", "tsx", "jsx", "sh", "rs", "go", "java", "c", "h", "cpp", "rb", "sql", "ipynb": return .code
    case "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml", "parquet", "xlsx", "xls", "db", "sqlite", "toml": return .data
    default: return .other
    }
}

/// The Library's search box and its two filters; nil means "all".
public func filterFiles(_ files: [HostFile], query: String, profile: String?, kind: FileKind?) -> [HostFile] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return files.filter { file in
        (profile == nil || file.profile == profile)
            && (kind == nil || fileKind(file.name) == kind)
            && (q.isEmpty || file.name.lowercased().contains(q) || file.path.lowercased().contains(q))
    }
}

// MARK: - Composer keys

public enum ReturnAction: Equatable { case send, newline, complete, passthrough }

/// What Return does in the composer. `composing` is the input method holding marked text
/// (pinyin being typed): Return then belongs to the input method and must never send.
public func returnAction(shift: Bool, option: Bool, enterSends: Bool, composing: Bool, paletteOpen: Bool) -> ReturnAction {
    if composing { return .passthrough }
    if shift || option { return .newline }
    if paletteOpen { return .complete }
    return enterSends ? .send : .newline
}
