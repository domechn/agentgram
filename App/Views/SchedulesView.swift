import SwiftUI
import AgentCore

struct JobForm: Identifiable {
    let id = UUID()
    var job: CronJob?
}

/// The timezone the schedule form's clock times are in. "host" is the zone Hermes itself uses.
enum ScheduleZone {
    static let choices = ["Asia/Shanghai", "UTC", "local", "host"]

    static func label(_ zone: String) -> String {
        switch zone {
        case "local": "This Mac (\(TimeZone.current.identifier))"
        case "host": "Hermes host"
        default: zone
        }
    }

    /// Seconds east of UTC.
    static func offset(_ zone: String, host: Int) -> Int {
        switch zone {
        case "local": TimeZone.current.secondsFromGMT()
        case "host": host
        default: TimeZone(identifier: zone)?.secondsFromGMT() ?? host
        }
    }
}

/// Hermes cron jobs of every bot: list, create, edit, pause, run now, delete, last output.
struct SchedulesView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("scheduleZone") private var zone = "Asia/Shanghai"
    @State private var form: JobForm?
    @State private var output: CronJob?
    @State private var deleting: CronJob?
    @State private var busy: String?

    var body: some View {
        let hermes = store.hermes
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Schedules") {
                if hermes.jobsLoading { ProgressView().controlSize(.small) }
                Spacer()
                Picker("Times in", selection: $zone) {
                    ForEach(ScheduleZone.choices, id: \.self) { Text(ScheduleZone.label($0)).tag($0) }
                }
                .fixedSize()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.jobsRefresh() } }
                    .disabled(!hermes.isConnected || hermes.jobsLoading)
                Button("New Schedule") { form = JobForm() }
                    .disabled(!hermes.isConnected || hermes.bridgeOutdated || hermes.profiles.isEmpty)
            }
            if !hermes.isConnected {
                ContentUnavailableView("Not connected to Hermes", systemImage: "calendar.badge.clock",
                                       description: Text("Open Settings (⌘,) to connect to your Hermes bridge."))
            } else if hermes.bridgeOutdated {
                ContentUnavailableView("Update the bridge", systemImage: "arrow.down.circle",
                                       description: Text("Schedules need hermes-bridge \(HermesState.requiredBridge) or newer; the host runs \(hermes.bridgeVersion). On the host: git pull, then sudo ./install.sh"))
            } else {
                if let error = hermes.jobsError {
                    ErrorBanner(text: error) { Task { await store.jobsRefresh() } }
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if hermes.jobs.isEmpty && !hermes.jobsLoaded {
                    SkeletonRows().padding(.horizontal, 12)
                    Spacer(minLength: 0)
                } else if hermes.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No schedules yet", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("A schedule runs a prompt with one of your bots every so often: a morning summary, a weekly review.")
                    } actions: {
                        Button("New Schedule") { form = JobForm() }.disabled(hermes.profiles.isEmpty)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(hermes.jobs.sorted { ($0.next_run ?? .infinity, $0.name) < ($1.next_run ?? .infinity, $1.name) }) { job in
                                row(job)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 2)
                        .frame(maxWidth: 860, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: hermes.isConnected) {
            // Next and last run move on their own: poll while visible (the bridge has no push).
            while !Task.isCancelled {
                await store.jobsRefresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .sheet(item: $form) { JobFormSheet(form: $0, zone: zone) }
        .sheet(item: $output) { JobOutputSheet(job: $0) }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { job in
            Button("Delete", role: .destructive) { act("delete", job) }
        } message: { _ in
            Text("The schedule is removed from the Hermes host. Output it already produced stays there.")
        }
    }

    private func spec(_ job: CronJob) -> ScheduleSpec {
        let host = store.hermes.jobOffsets[job.profile] ?? 0
        return scheduleSpec(kind: job.kind, expr: job.expr, minutes: job.minutes,
                            zoneOffset: ScheduleZone.offset(zone, host: host), hostOffset: host)
    }

    /// "Daily at 10:00", or what Hermes calls it when the builder cannot express it.
    private func title(_ job: CronJob) -> String {
        let spec = spec(job)
        if case .cron = spec { return job.display.isEmpty ? job.expr : job.display }
        return describeSchedule(spec)
    }

    private func row(_ job: CronJob) -> some View {
        let paused = !job.enabled || job.state == "paused"
        let failed = !job.last_error.isEmpty || (!job.last_status.isEmpty && job.last_status != "ok")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(path: nil, title: job.profile, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(job.profile).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(paused ? "Paused" : job.state.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(paused ? Color.secondary : job.state == "running" ? Color.blue : Color.green)
                    .background((paused ? Color.gray : job.state == "running" ? Color.blue : Color.green).opacity(0.14), in: Capsule())
            }
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(title(job))
                if job.kind == "cron", !job.expr.isEmpty {
                    Text(job.expr).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        .help("Cron expression, in the Hermes host's timezone")
                }
            }
            .font(.callout)
            if !job.prompt.isEmpty || !job.script.isEmpty {
                Text(job.no_agent || job.prompt.isEmpty ? "Runs script \(job.script)" : job.prompt)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 14) {
                Label("Next \(paused ? "—" : stamp(job.next_run))", systemImage: "arrow.right.circle")
                Label("Last \(stamp(job.last_run))\(job.last_status.isEmpty ? "" : " · " + job.last_status)",
                      systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .help(job.last_error)
                Label(job.deliver, systemImage: "paperplane").help("Where the result is delivered")
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Button("Run Now") { act("run", job) }
                Button(paused ? "Resume" : "Pause") { act(paused ? "resume" : "pause", job) }
                Button("Edit…") { form = JobForm(job: job) }
                Button("Last Output") { output = job }.disabled(job.last_run == nil)
                if busy == job.id { ProgressView().controlSize(.small) }
                Spacer()
                Button("Delete…", role: .destructive) { deleting = job }
            }
            .controlSize(.small)
            .disabled(busy != nil)
        }
        .padding(12)
        .card(radius: 12)
        .opacity(paused ? 0.75 : 1)
    }

    private func act(_ action: String, _ job: CronJob) {
        busy = job.id
        Task {
            if await store.jobAction(action, job), action == "run" { store.toast = "“\(job.name)” is queued to run now." }
            busy = nil
        }
    }
}

/// Create or edit a schedule. The builder covers the common shapes; anything else is raw cron.
struct JobFormSheet: View {
    enum Mode: String, CaseIterable { case minutes = "Every N minutes", hours = "Every N hours", daily = "Daily", weekly = "Weekly", cron = "Cron" }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let form: JobForm
    @State var zone: String
    @State private var profile = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var mode = Mode.daily
    @State private var every = 30
    @State private var hour = 9
    @State private var minute = 0
    @State private var days: Set<Int> = [1, 2, 3, 4, 5]
    @State private var cron = "0 9 * * *"
    @State private var busy = false
    @State private var error: String?

    private var hostOffset: Int { store.hermes.jobOffsets[profile] ?? 0 }

    private var spec: ScheduleSpec {
        switch mode {
        case .minutes: .minutes(every)
        case .hours: .hours(every)
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(days: days, hour: hour, minute: minute)
        case .cron: .cron(cron)
        }
    }

    private var isScript: Bool { form.job?.no_agent == true }

    private var valid: Bool {
        !profile.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && isValidSchedule(spec)
            && (isScript || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !deliver.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.job == nil ? "New schedule" : "Edit schedule").font(.headline)
            Form {
                Picker("Bot", selection: $profile) {
                    ForEach(store.hermes.profiles) { Text($0.name).tag($0.name) }
                }
                .disabled(form.job != nil) // a job lives in its profile's store
                TextField("Name", text: $name, prompt: Text("e.g. morning summary"))
                Picker("Repeat", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                switch mode {
                case .minutes:
                    Stepper("Every \(every) minute\(every == 1 ? "" : "s")", value: $every, in: 1...10080)
                case .hours:
                    Stepper("Every \(every) hour\(every == 1 ? "" : "s")", value: $every, in: 1...168)
                case .daily, .weekly:
                    HStack {
                        Picker("At", selection: $hour) {
                            ForEach(0..<24, id: \.self) { Text($0 < 10 ? "0\($0)" : "\($0)").tag($0) }
                        }
                        .fixedSize()
                        Text(":")
                        Picker("Minute", selection: $minute) {
                            ForEach(0..<60, id: \.self) { Text($0 < 10 ? "0\($0)" : "\($0)").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if mode == .weekly {
                        HStack(spacing: 4) {
                            // Monday first; cron counts from Sunday = 0.
                            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                                Toggle(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day], isOn: Binding(
                                    get: { days.contains(day) },
                                    set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                                    .toggleStyle(.button).controlSize(.small)
                            }
                        }
                    }
                    Picker("Timezone", selection: $zone) {
                        ForEach(ScheduleZone.choices, id: \.self) { Text(ScheduleZone.label($0)).tag($0) }
                    }
                case .cron:
                    TextField("Cron", text: $cron, prompt: Text("minute hour day month weekday"))
                        .font(.body.monospaced())
                }
                HStack {
                    TextField("Deliver to", text: $deliver, prompt: Text("local"))
                    Menu("Presets") {
                        Button("local — keep the output on the host") { deliver = "local" }
                        Button("telegram — the bot's Telegram home chat") { deliver = "telegram" }
                        Button("origin — the chat the job was created from") { deliver = "origin" }
                    }
                    .fixedSize()
                }
            }
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isScript {
                Text("This job runs the script \(form.job?.script ?? "") without an agent, so it has no prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prompt).font(.body).frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("Prompt")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(form.job == nil ? "Create" : "Save", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!valid || busy)
            }
        }
        .padding(16)
        .frame(width: 500)
        .onAppear(perform: load)
    }

    /// What will be sent to Hermes, in words and as the string it takes.
    private var summary: String {
        guard isValidSchedule(spec) else {
            return mode == .weekly && days.isEmpty ? "Pick at least one day." : "Not a valid schedule: cron needs five fields (minute hour day month weekday)."
        }
        let text = scheduleString(spec, zoneOffset: ScheduleZone.offset(zone, host: hostOffset), hostOffset: hostOffset)
        switch mode {
        case .minutes, .hours: return "\(describeSchedule(spec)) (Hermes: “\(text)”)."
        case .daily, .weekly: return "\(describeSchedule(spec)), \(ScheduleZone.label(zone)) time. On the host this is cron “\(text)”."
        case .cron: return "Cron expressions are evaluated in the Hermes host's timezone."
        }
    }

    private func load() {
        guard let job = form.job else {
            if let selected = store.selection.flatMap({ store.agent($0.chatId)?.hermes }) { profile = selected }
            if profile.isEmpty { profile = store.hermes.profiles.first?.name ?? "" }
            return
        }
        profile = job.profile
        name = job.name
        prompt = job.prompt
        deliver = job.deliver
        let host = store.hermes.jobOffsets[job.profile] ?? 0
        switch scheduleSpec(kind: job.kind, expr: job.expr, minutes: job.minutes,
                            zoneOffset: ScheduleZone.offset(zone, host: host), hostOffset: host) {
        case .minutes(let n):
            mode = .minutes
            every = n
        case .hours(let n):
            mode = .hours
            every = n
        case .daily(let h, let m):
            mode = .daily
            hour = h
            minute = m
        case .weekly(let d, let h, let m):
            mode = .weekly
            days = d
            hour = h
            minute = m
        case .cron(let expr):
            mode = .cron
            cron = expr.isEmpty ? job.display : expr
        }
    }

    private func submit() {
        busy = true
        error = nil
        let schedule = scheduleString(spec, zoneOffset: ScheduleZone.offset(zone, host: hostOffset), hostOffset: hostOffset)
        Task {
            do {
                try await store.jobSave(form.job, profile: profile, name: name.trimmingCharacters(in: .whitespaces), schedule: schedule,
                                        prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                        deliver: deliver.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                self.error = describe(error)
            }
            busy = false
        }
    }
}

/// What the job's newest run answered.
struct JobOutputSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: CronJob
    @State private var output: JobOutput?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.headline)
                Text(output.map { $0.file.isEmpty ? "No saved output" : "Run of \(stamp($0.ts)) · \($0.file)" } ?? "Loading…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    if let output {
                        if output.text.isEmpty {
                            Text("This job has not saved any output yet.").foregroundStyle(.secondary)
                        } else {
                            MarkdownView(blocks: parseBlocks(output.text))
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        SkeletonRows(count: 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let text = output?.text, !text.isEmpty {
                    Button("Copy") {
                        Pasteboard.copy(text)
                        store.toast = "Copied"
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 560)
        .task {
            do { output = try await store.jobOutput(job) } catch { self.error = describe(error) }
        }
    }
}
