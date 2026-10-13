import SwiftUI
import EventKit
import ServiceManagement
import AVFoundation

struct Item: Identifiable {
    let id: String
    let title: String
    let time: String
    let color: Color
    let sort: Date
    let isReminder: Bool
    let open: URL?
    let join: URL?
    var done = false
    var past = false
    var rid: String? = nil
    var aid: String? = nil
}

let linkRx = try! Regex(#"https?://[^\s<>"]*(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#)

func meetingLink(_ e: EKEvent) -> URL? {
    for s in [e.url?.absoluteString, e.location, e.notes] {
        if let s, let m = s.firstMatch(of: linkRx) { return URL(string: String(s[m.range])) }
    }
    return nil
}

func aid(_ e: EKEvent) -> String { (e.eventIdentifier ?? "") + "\(e.startDate.timeIntervalSince1970)" }

struct Alert { let id: String; let title: String; let start: Date; let join: URL? }

final class AlertWindow: NSWindow { override var canBecomeKey: Bool { true } }

struct AlertView: View {
    let a: Alert
    @ObservedObject var store: Store
    let onJoin: () -> Void, onSnooze: () -> Void, onCancel: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                // buzz 0.6s, rest 0.6s
                let angle = t.truncatingRemainder(dividingBy: 1.2) < 0.6 ? sin(t * 60) * 14 : 0
                Image(systemName: "alarm.fill").font(.system(size: 220)).foregroundStyle(.white).rotationEffect(.degrees(angle))
            }
            Text(a.title).font(.system(size: 44, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(a.start.formatted(date: .omitted, time: .shortened)).font(.title2).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 20) {
                if a.join != nil { Button("Join", action: onJoin).buttonStyle(.borderedProminent).tint(.green) }
                Button("Snooze 30s", action: onSnooze).buttonStyle(.bordered).tint(.white)
                Button("Cancel", action: onCancel).buttonStyle(.bordered).tint(.white)
                Button { store.toggleMute() } label: { Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.bordered).tint(.white).help(store.muted ? "Unmute" : "Mute")
            }.controlSize(.extraLarge)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class Store: ObservableObject {
    let ek = EKEventStore()
    @Published var items: [Item] = []
    @Published var denied = false
    @Published var bar = ""
    var targets: [Alert] = []
    var shown: Alert?
    @Published var barCals: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "barCals") ?? [UserDefaults.standard.string(forKey: "barCal") ?? ""].filter { !$0.isEmpty }) {
        didSet { UserDefaults.standard.set(Array(barCals), forKey: "barCals") }
    }
    @Published var alertCals: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "alertCals") ?? [UserDefaults.standard.string(forKey: "barCal") ?? ""].filter { !$0.isEmpty }) {
        didSet { UserDefaults.standard.set(Array(alertCals), forKey: "alertCals") }
    }
    var testAlert: Alert?
    var dismissed: Set<String> = []
    @Published var snoozed: [String: Date] = [:]
    var windows: [NSWindow] = []
    var ticks = 0
    @Published var muted = false
    var player: AVAudioPlayer?
    var savedVolume: Int?

    @discardableResult func script(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    // Focus state: needs Full Disk Access for TodayBar; unreadable -> false
    var focusOn: Bool {
        let u = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json")
        guard let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let r = (j["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [Any] else { return false }
        return !r.isEmpty
    }

    // ponytail: heuristic (mirrored display or Zoom's CptHost share process); misses browser-based sharing
    var sharing: Bool {
        if NSScreen.screens.contains(where: { CGDisplayIsInMirrorSet($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID) != 0 }) { return true }
        return NSWorkspace.shared.runningApplications.contains { $0.localizedName == "CptHost" }
    }

    var quiet: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "quietFocus") && focusOn { return true }
        if d.bool(forKey: "quietShare") && sharing { return true }
        if d.bool(forKey: "quietHours") {
            let h = Calendar.current.component(.hour, from: .now), a = d.integer(forKey: "quietFrom"), b = d.integer(forKey: "quietTo")
            return a <= b ? (a..<b).contains(h) : (h >= a || h < b)
        }
        return false
    }

    func startSound() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "alarm"), !muted, player == nil, !quiet else { return }
        // iPhone "Radar" ringtone ships with macOS; fall back to a system sound
        let radar = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Radar.m4r")
        let url = FileManager.default.fileExists(atPath: radar.path) ? radar : URL(fileURLWithPath: "/System/Library/Sounds/Funk.aiff")
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        // absolute volume: set system output level while alarm plays, restore after
        if savedVolume == nil { savedVolume = script("output volume of (get volume settings)").map { Int($0.int32Value) } }
        script("set volume output volume \(Int(d.double(forKey: "alarmVol"))) without output muted")
        p.numberOfLoops = -1
        p.play()
        player = p
    }

    func stopSound() {
        player?.stop(); player = nil
        if let v = savedVolume { script("set volume output volume \(v)"); savedVolume = nil }
    }

    func toggleMute() { muted.toggle(); if muted { stopSound() } else { startSound() } }

    func test() { testAlert = Alert(id: "test\(UUID())", title: "Test meeting", start: .now.addingTimeInterval(UserDefaults.standard.double(forKey: "alertLead")), join: URL(string: "https://zoom.us/j/123")) }

    func tick() {
        ticks += 1
        let now = Date.now
        let lead = UserDefaults.standard.double(forKey: "alertLead")
        let cands = (testAlert.map { [$0] } ?? []) + (UserDefaults.standard.bool(forKey: "alert") ? targets.filter { $0.join != nil || !UserDefaults.standard.bool(forKey: "linkOnly") } : [])
        let due = cands.first {
            $0.start.timeIntervalSince(now) <= lead && now < $0.start.addingTimeInterval(300)
                && !dismissed.contains($0.id) && (snoozed[$0.id] ?? .distantPast) <= now
        }
        guard let a = due, !(UserDefaults.standard.bool(forKey: "hideOnShare") && sharing) else { hideAlert(); return }
        if shown?.id != a.id { hideAlert(); showAlert(a) }
    }

    func showAlert(_ a: Alert) {
        for screen in NSScreen.screens {
            let w = AlertWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.9)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.contentView = NSHostingView(rootView: AlertView(a: a, store: self,
                onJoin: { [self] in if let j = a.join { NSWorkspace.shared.open(j) }; dismiss(a) },
                onSnooze: { [self] in snoozed[a.id] = .now.addingTimeInterval(30); hideAlert() },
                onCancel: { [self] in dismiss(a) }))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        shown = a
        NSApp.activate(ignoringOtherApps: true)
        muted = false
        startSound()
    }

    func hideAlert() { windows.forEach { $0.close() }; windows = []; shown = nil; stopSound() }

    func dismiss(_ a: Alert) { dismissId(a.id) }

    func dismissId(_ id: String) {
        dismissed.insert(id)
        snoozed[id] = nil
        if testAlert?.id == id { testAlert = nil }
        if shown?.id == id { hideAlert() }
    }
    @Published var calendars: [EKCalendar] = []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }

    init() {
        UserDefaults.standard.register(defaults: ["indicators": true, "allDay": true, "endTime": true, "pastMode": 0, "completed": true, "alert": true, "alarm": true, "alarmVol": 30.0, "alertLead": 30.0, "quietFocus": true, "quietShare": true, "hideOnShare": false, "linkOnly": true, "quietFrom": 22, "quietTo": 8])
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyTheme(); await self?.load() }
        }
        applyTheme()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in await self?.load() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        Task { await load() }
    }

    func applyTheme() {
        NSApp?.appearance = [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][UserDefaults.standard.integer(forKey: "theme")]
    }

    func toggle(_ i: Item) {
        guard let id = i.rid, let r = ek.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted.toggle()
        try? ek.save(r, commit: true)
        Task { await load() }
    }

    func load() async {
        let ev = (try? await ek.requestFullAccessToEvents()) ?? false
        let rem = (try? await ek.requestFullAccessToReminders()) ?? false
        denied = !ev && !rem
        calendars = (ev ? ek.calendars(for: .event) : []) + (rem ? ek.calendars(for: .reminder) : [])
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let d = UserDefaults.standard
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let fmt = tf
        var out: [Item] = []

        bar = ""
        targets = []
        let bc = ek.calendars(for: .event).filter { barCals.contains($0.calendarIdentifier) }
        if ev, !bc.isEmpty {
            let p = ek.predicateForEvents(withStart: .now, end: end, calendars: bc)
            if let e = ek.events(matching: p).filter({ !$0.isAllDay && $0.endDate > .now }).min(by: { $0.startDate < $1.startDate }) {
                let t = e.title ?? ""
                bar = fmt.string(from: e.startDate) + " " + (t.count > 24 ? t.prefix(24) + "…" : t)
            }
        }

        if ev {
            let ac = ek.calendars(for: .event).filter { alertCals.contains($0.calendarIdentifier) }
            if !ac.isEmpty {
                let p = ek.predicateForEvents(withStart: .now, end: end, calendars: ac)
                targets = ek.events(matching: p).filter { !$0.isAllDay && $0.endDate > .now }.sorted { $0.startDate < $1.startDate }
                    .map { Alert(id: aid($0), title: $0.title ?? "", start: $0.startDate, join: meetingLink($0)) }
            }
        }

        if ev {
            let cals = ek.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
            if !cals.isEmpty {
                let p = ek.predicateForEvents(withStart: start, end: end, calendars: cals)
                for e in ek.events(matching: p) {
                    if e.isAllDay && !d.bool(forKey: "allDay") { continue }
                    if !e.isAllDay && e.endDate < .now && d.integer(forKey: "pastMode") == 2 { continue }
                    let t = e.isAllDay ? "All day" : d.bool(forKey: "endTime") ? "\(fmt.string(from: e.startDate)) – \(fmt.string(from: e.endDate))" : fmt.string(from: e.startDate)
                    let eid = e.eventIdentifier ?? UUID().uuidString
                    out.append(Item(id: "e\(eid)\(e.startDate.timeIntervalSince1970)", title: e.title ?? "", time: t,
                                    color: Color(cgColor: e.calendar.cgColor), sort: e.isAllDay ? start : e.startDate, isReminder: false,
                                    open: URL(string: "ical://ekevent/\(eid)?method=show&options=more"), join: meetingLink(e), past: !e.isAllDay && e.endDate < .now, aid: aid(e)))
                }
            }
        }
        if rem {
            let cals = ek.calendars(for: .reminder).filter { !hidden.contains($0.calendarIdentifier) }
            if !cals.isEmpty {
                // incomplete reminders due today or overdue
                let p = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: cals)
                var rs: [EKReminder] = await withCheckedContinuation { c in ek.fetchReminders(matching: p) { c.resume(returning: $0 ?? []) } }
                if d.bool(forKey: "completed") {
                    let pc = ek.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: cals)
                    rs += await withCheckedContinuation { c in ek.fetchReminders(matching: pc) { c.resume(returning: $0 ?? []) } }
                }
                for r in rs {
                    let comps = r.dueDateComponents
                    guard let due = comps.flatMap({ cal.date(from: $0) }) ?? r.completionDate else { continue }
                    out.append(Item(id: "r" + r.calendarItemIdentifier, title: r.title ?? "", time: comps?.hour != nil || comps == nil ? fmt.string(from: due) : "Reminder",
                                    color: Color(cgColor: r.calendar.cgColor), sort: max(due, start), isReminder: true,
                                    open: URL(string: "x-apple-reminderkit://REMCDReminder/\(r.calendarItemIdentifier)"), join: nil,
                                    done: r.isCompleted, rid: r.calendarItemIdentifier))
                }
            }
        }
        items = out.sorted { $0.sort < $1.sort }
    }
}

final class Flag: ObservableObject { @Published var on = false } // @State macro plugin missing under bare swiftc

struct Row: View {
    let i: Item
    @ObservedObject var store: Store
    @StateObject private var h = Flag()
    @AppStorage("indicators") private var indicators = true
    @AppStorage("pastMode") private var pastMode = 0
    var body: some View {
        HStack(spacing: 8) {
            if indicators { RoundedRectangle(cornerRadius: 2).fill(i.color).frame(width: 4, height: 32) }
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title).lineLimit(2).strikethrough(i.done).foregroundStyle(i.done ? .secondary : .primary)
                Text(i.time).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let id = i.aid, store.snoozed[id] != nil {
                Button { store.dismissId(id) } label: { Image(systemName: "zzz").foregroundStyle(.orange) }.buttonStyle(.plain).help("Cancel snoozed alert")
            }
            if let j = i.join { Button("Join") { NSWorkspace.shared.open(j); if let id = i.aid { store.dismissId(id) } }.buttonStyle(.borderedProminent).controlSize(.small) }
            if i.isReminder { Button { store.toggle(i) } label: { Image(systemName: i.done ? "checkmark.circle.fill" : "circle").foregroundStyle(i.color) }.buttonStyle(.plain) }
        }
        .opacity(i.past && pastMode == 0 ? 0.4 : 1)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(h.on ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { h.on = $0 }
        .onTapGesture { if let u = i.open { NSWorkspace.shared.open(u) } }
    }
}

struct CalendarsTab: View {
    @ObservedObject var store: Store
    var body: some View {
        let groups = Dictionary(grouping: store.calendars, by: { $0.source.title })
        Form {
            ForEach(groups.keys.sorted(), id: \.self) { src in
                Section(src) {
                    ForEach(groups[src]!, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(
                            get: { !store.hidden.contains(c.calendarIdentifier) },
                            set: { on in if on { store.hidden.remove(c.calendarIdentifier) } else { store.hidden.insert(c.calendarIdentifier) } }
                        )) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(cgColor: c.cgColor)).frame(width: 12, height: 12)
                                Text(c.title)
                                if c.allowedEntityTypes.contains(.reminder) { Text("reminders").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }.formStyle(.grouped).task { await store.load() }
    }
}

func dot(_ c: CGColor) -> NSImage {
    let i = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        NSColor(cgColor: c)?.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
    }
    i.isTemplate = false
    return i
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage("login") private var login = false
    @AppStorage("theme") private var theme = 0
    @AppStorage("indicators") private var indicators = true
    @AppStorage("allDay") private var allDay = true
    @AppStorage("endTime") private var endTime = true
    @AppStorage("pastMode") private var pastMode = 0
    @AppStorage("completed") private var completed = true
    @AppStorage("alert") private var alert = true
    @AppStorage("alarm") private var alarm = true
    @AppStorage("alertLead") private var lead = 30.0
    @AppStorage("alarmVol") private var alarmVol = 30.0
    @AppStorage("quietFocus") private var quietFocus = true
    @AppStorage("quietShare") private var quietShare = true
    @AppStorage("linkOnly") private var linkOnly = true
    @AppStorage("hideOnShare") private var hideOnShare = false
    @AppStorage("quietHours") private var quietHours = false
    @AppStorage("quietFrom") private var quietFrom = 22
    @AppStorage("quietTo") private var quietTo = 8
    var body: some View {
        TabView {
            Form { Toggle("Launch at login", isOn: $login) }.formStyle(.grouped)
                .onChange(of: login) { _, on in if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
                .tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Picker("Theme", selection: $theme) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
                Section("Show") {
                    Toggle("Calendar indicators", isOn: $indicators)
                    Toggle("All-day events", isOn: $allDay)
                    Toggle("End time for events", isOn: $endTime)
                    Picker("Today’s past events", selection: $pastMode) { Text("Grayed out").tag(0); Text("Normal").tag(1); Text("Hidden").tag(2) }
                    Toggle("Completed reminders", isOn: $completed)
                }
            }.formStyle(.grouped).tabItem { Label("Appearance", systemImage: "paintbrush") }
            Form {
                Section("Show next event from") {
                    ForEach(store.calendars.filter { $0.allowedEntityTypes.contains(.event) }, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(
                            get: { store.barCals.contains(c.calendarIdentifier) },
                            set: { on in if on { store.barCals.insert(c.calendarIdentifier) } else { store.barCals.remove(c.calendarIdentifier) } }
                        )) {
                            Label { Text("\(c.title) — \(c.source.title)") } icon: { Image(nsImage: dot(c.cgColor)) }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            Form {
                Section("Alert") {
                    Toggle("Full-screen alert before a meeting", isOn: $alert)
                    Toggle("Only for events with a meeting link", isOn: $linkOnly)
                    Stepper("Trigger \(Int(lead)) seconds before", value: $lead, in: 0...3600, step: 5)
                    Toggle("Play alarm sound", isOn: $alarm)
                    Slider(value: $alarmVol, in: 0...100, step: 5) { Text("Alarm volume \(Int(alarmVol))%") }
                    Button("Test alert") { store.test() }
                }
                Section("Silence alarm sound when") {
                    Toggle("Focus / Do Not Disturb is on", isOn: $quietFocus)
                    Toggle("Screen is shared or mirrored", isOn: $quietShare)
                    Toggle("Quiet hours", isOn: $quietHours)
                    Toggle("Also hide the full-screen alert while screen is shared", isOn: $hideOnShare)
                    if quietHours {
                        Picker("From", selection: $quietFrom) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        Picker("To", selection: $quietTo) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    }
                }
                Section("Calendars that trigger the alert") {
                    ForEach(store.calendars.filter { $0.allowedEntityTypes.contains(.event) }, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(
                            get: { store.alertCals.contains(c.calendarIdentifier) },
                            set: { on in if on { store.alertCals.insert(c.calendarIdentifier) } else { store.alertCals.remove(c.calendarIdentifier) } }
                        )) {
                            Label { Text("\(c.title) — \(c.source.title)") } icon: { Image(nsImage: dot(c.cgColor)) }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Alerts", systemImage: "alarm") }
            CalendarsTab(store: store).tabItem { Label("Calendars", systemImage: "calendar") }
        }.frame(width: 460, height: 560)
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    @Environment(\.openSettings) private var openSettings
    var headerDate: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM d, EEEE"
        return f.string(from: .now)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headerDate).font(.headline)
                Spacer()
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Divider()
            if store.denied {
                Text("Allow Calendar/Reminders access in System Settings › Privacy & Security.").font(.callout)
            } else if store.items.isEmpty {
                Text("Nothing today").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) { ForEach(store.items) { i in Row(i: i, store: store) } }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 320)
        .task { await store.load() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await store.load() } }
    }
}

let barIcon: NSImage = {
    let i = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Today")!
        .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!
    i.isTemplate = true
    return i
}()

@main
struct TodayBar: App {
    @StateObject var store = Store()
    var body: some Scene {
        MenuBarExtra { Panel(store: store) } label: { HStack(spacing: 4) { Image(nsImage: barIcon); if !store.bar.isEmpty { Text(store.bar) } } }
            .menuBarExtraStyle(.window)
        Settings { SettingsView(store: store) }
    }
}
