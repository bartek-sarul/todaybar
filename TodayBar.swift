import SwiftUI
import EventKit
import ServiceManagement
import AVFoundation
import CoreAudio

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
    let onJoin: () -> Void, onSnooze: (TimeInterval) -> Void, onCancel: () -> Void
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
                Button("Snooze 30s") { onSnooze(30) }.buttonStyle(.bordered).tint(.white)
                Button("Snooze 1m") { onSnooze(60) }.buttonStyle(.bordered).tint(.white)
                Button("Cancel", action: onCancel).buttonStyle(.bordered).tint(.white)
                let off = !UserDefaults.standard.bool(forKey: "alarm")
                let silent = off || store.muted
                Button { store.toggleMute() } label: { Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 30) }
                    .buttonStyle(.bordered).tint(.white).disabled(off).help(off ? "Alarm sound is off in settings" : store.muted ? "Unmute" : "Mute")
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
    @Published var update: String?
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
    var soundStart = Date.now
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

    // ponytail: heuristic, true while any app records from the default mic (Zoom/Teams/Meet in browser, but also dictation)
    var inCall: Bool {
        var dev = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == 0 else { return false }
        var on: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        a.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &on) == 0 && on != 0
    }

    var quiet: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: "quietFocus") && focusOn { return true }
        if d.bool(forKey: "quietShare") && sharing { return true }
        if d.bool(forKey: "quietHours") {
            return inQuietHours(hour: Calendar.current.component(.hour, from: .now), from: d.integer(forKey: "quietFrom"), to: d.integer(forKey: "quietTo"))
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
        soundStart = .now
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
        if player != nil, now.timeIntervalSince(soundStart) >= UserDefaults.standard.double(forKey: "alarmMins") * 60 { stopSound() }
        if snoozed.values.contains(where: { $0 <= now }) { snoozed = activeSnoozes(snoozed, now: now) }
        let cands = (testAlert.map { [$0] } ?? []) + (UserDefaults.standard.bool(forKey: "alert") && !(UserDefaults.standard.bool(forKey: "skipInCall") && inCall) ? targets.filter { $0.join != nil || !UserDefaults.standard.bool(forKey: "linkOnly") } : [])
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
                onSnooze: { [self] secs in snoozed[a.id] = .now.addingTimeInterval(secs); hideAlert() },
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
    @Published var evOK = true
    @Published var remOK = true
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }

    init() {
        UserDefaults.standard.register(defaults: ["indicators": true, "allDay": true, "endTime": true, "pastMode": 0, "completed": true, "alert": true, "bar": true, "alarmMins": 5, "barTime": true, "barName": true, "showEvents": true, "showReminders": true, "alarm": true, "alarmVol": 30.0, "alertLead": 30.0, "quietFocus": true, "quietShare": true, "hideOnShare": false, "skipInCall": true, "linkOnly": true, "quietFrom": 22, "quietTo": 8])
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyTheme(); await self?.load() }
        }
        applyTheme()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in await self?.load() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        Task { await load() }
        Task { await checkUpdate() }
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in Task { @MainActor in await self?.checkUpdate() } }
    }

    func checkUpdate() async {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/bartek-sarul/todaybar/releases/latest")!),
              let tag = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["tag_name"] as? String,
              isNewer(tag, than: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
        else { return }
        update = tag
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
        evOK = ev; remOK = rem
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
        if ev, d.bool(forKey: "bar"), !bc.isEmpty {
            let p = ek.predicateForEvents(withStart: .now, end: end, calendars: bc)
            let up = ek.events(matching: p).filter { !$0.isAllDay && $0.endDate > .now }.sorted { $0.startDate < $1.startDate }
            if let e = pickBarEvent(up, start: { $0.startDate }, now: .now) {
                bar = barTitle(time: fmt.string(from: e.startDate), name: e.title ?? "", showTime: d.bool(forKey: "barTime"), showName: d.bool(forKey: "barName"))
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

        if ev, d.bool(forKey: "showEvents") {
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
        if rem, d.bool(forKey: "showReminders") {
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
    var next = false
    @ObservedObject var store: Store
    @StateObject private var h = Flag()
    @AppStorage("indicators") private var indicators = true
    @AppStorage("pastMode") private var pastMode = 0
    var body: some View {
        HStack(spacing: 8) {
            if indicators { RoundedRectangle(cornerRadius: 2).fill(i.color).frame(width: 4, height: 32) }
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title).fontWeight(next ? .bold : .regular).lineLimit(2).strikethrough(i.done).foregroundStyle(i.done ? .secondary : .primary)
                Text(i.time).font(.caption).fontWeight(next ? .semibold : .regular).foregroundStyle(next ? Color.accentColor : .secondary)
            }
            Spacer(minLength: 0)
            if let id = i.aid, store.snoozed[id] != nil {
                Button("Zzz") { store.dismissId(id) }.buttonStyle(.bordered).tint(.orange).controlSize(.small).help("Cancel snoozed alert")
            }
            if let j = i.join { Button("Join") { NSWorkspace.shared.open(j); if let id = i.aid { store.dismissId(id) } }.buttonStyle(.borderedProminent).controlSize(.small) }
            if i.isReminder { Button { store.toggle(i) } label: { Image(systemName: i.done ? "checkmark.circle.fill" : "circle").foregroundStyle(i.color) }.buttonStyle(.plain) }
        }
        .opacity(i.past && pastMode == 0 ? 0.4 : 1)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(h.on ? 0.1 : next ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { h.on = $0 }
        .onTapGesture { if let u = i.open { NSWorkspace.shared.open(u) } }
    }
}

func permRow(_ name: String, _ pane: String) -> some View {
    HStack {
        Label("\(name) access not granted", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        Spacer()
        Button("Open Privacy Settings") {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(u) }
        }
    }
}

/// Per-calendar visibility toggles shared by the Calendars and Reminders tabs.
struct CalendarList: View {
    @ObservedObject var store: Store
    let kind: EKEntityMask
    let title: String
    var body: some View {
        Section(title) {
            ForEach(store.calendars.filter { $0.allowedEntityTypes.contains(kind) }, id: \.calendarIdentifier) { c in
                Toggle(isOn: Binding(
                    get: { !store.hidden.contains(c.calendarIdentifier) },
                    set: { on in if on { store.hidden.remove(c.calendarIdentifier) } else { store.hidden.insert(c.calendarIdentifier) } }
                )) {
                    Label { Text("\(c.title) — \(c.source.title)") } icon: { Image(nsImage: dot(c.cgColor)) }
                }
            }
        }
    }
}

struct EventsTab: View {
    @ObservedObject var store: Store
    @AppStorage("indicators") private var indicators = true
    @AppStorage("allDay") private var allDay = true
    @AppStorage("endTime") private var endTime = true
    @AppStorage("pastMode") private var pastMode = 0
    @AppStorage("showEvents") private var showEvents = true
    var body: some View {
        Form {
            if !store.evOK { permRow("Calendar", "Calendars") } else {
                Section { Toggle("Show calendar events in the list", isOn: $showEvents) }
                if showEvents {
                    Section {
                        Toggle("Calendar indicators", isOn: $indicators)
                        Toggle("All-day events", isOn: $allDay)
                        Toggle("End time for events", isOn: $endTime)
                        Picker("Today’s past events", selection: $pastMode) { Text("Grayed out").tag(0); Text("Normal").tag(1); Text("Hidden").tag(2) }
                    }
                    CalendarList(store: store, kind: .event, title: "Calendars shown in the list")
                }
            }
        }.formStyle(.grouped).task { await store.load() }
    }
}

struct RemindersTab: View {
    @ObservedObject var store: Store
    @AppStorage("completed") private var completed = true
    @AppStorage("showReminders") private var showReminders = true
    var body: some View {
        Form {
            if !store.remOK { permRow("Reminders", "Reminders") } else {
                Section { Toggle("Show reminders in the list", isOn: $showReminders) }
                if showReminders {
                    Section { Toggle("Completed reminders", isOn: $completed) }
                    CalendarList(store: store, kind: .reminder, title: "Reminder lists shown in the list")
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
    @AppStorage("bar") private var bar = true
    @AppStorage("barTime") private var barTime = true
    @AppStorage("barName") private var barName = true
    @AppStorage("theme") private var theme = 0
    @AppStorage("alert") private var alert = true
    @AppStorage("alarm") private var alarm = true
    @AppStorage("alertLead") private var lead = 30.0
    @AppStorage("alarmMins") private var alarmMins = 5
    @AppStorage("alarmVol") private var alarmVol = 30.0
    @AppStorage("quietFocus") private var quietFocus = true
    @AppStorage("quietShare") private var quietShare = true
    @AppStorage("linkOnly") private var linkOnly = true
    @AppStorage("hideOnShare") private var hideOnShare = false
    @AppStorage("skipInCall") private var skipInCall = true
    @AppStorage("quietHours") private var quietHours = false
    @AppStorage("quietFrom") private var quietFrom = 22
    @AppStorage("quietTo") private var quietTo = 8
    var body: some View {
        TabView {
            Form {
                Toggle("Launch at login", isOn: $login)
                Picker("Theme", selection: $theme) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
            }.formStyle(.grouped)
                .onChange(of: login) { _, on in if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
                .tabItem { Label("General", systemImage: "gearshape") }
            Form {
                if !store.evOK { permRow("Calendar", "Calendars") }
                if store.evOK { Section { Toggle("Show next event in menu bar", isOn: $bar) }
                if bar { Section {
                    Toggle("Show time", isOn: $barTime)
                    Toggle("Show event name", isOn: $barName)
                }
                Section("Show next event from") {
                    ForEach(store.calendars.filter { $0.allowedEntityTypes.contains(.event) }, id: \.calendarIdentifier) { c in
                        Toggle(isOn: Binding(
                            get: { store.barCals.contains(c.calendarIdentifier) },
                            set: { on in if on { store.barCals.insert(c.calendarIdentifier) } else { store.barCals.remove(c.calendarIdentifier) } }
                        )) {
                            Label { Text("\(c.title) — \(c.source.title)") } icon: { Image(nsImage: dot(c.cgColor)) }
                        }
                    }
                } } }
            }.formStyle(.grouped).tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            Form {
                if !store.evOK { permRow("Calendar", "Calendars") } else {
                Section { Toggle("Full-screen alert before a meeting", isOn: $alert) }
                if alert {
                Section {
                    Toggle("Only for events with a meeting link", isOn: $linkOnly)
                    Toggle("Skip when already in a call (microphone in use)", isOn: $skipInCall)
                    Stepper("Trigger \(Int(lead)) seconds before", value: $lead, in: 0...3600, step: 5)
                    Toggle("Play alarm sound", isOn: $alarm)
                    if alarm {
                        Stepper("Play for \(alarmMins) minute\(alarmMins == 1 ? "" : "s")", value: $alarmMins, in: 1...60)
                        Slider(value: $alarmVol, in: 0...100, step: 5) { Text("Alarm volume \(Int(alarmVol))%") }
                    }
                    Button("Test alert") { store.test() }
                }
                Section("Silence alarm sound when") {
                    Toggle("Focus / Do Not Disturb is on", isOn: $quietFocus)
                    Toggle("Screen is shared or mirrored", isOn: $quietShare)
                    Toggle("Hide the full-screen alert while screen is shared", isOn: $hideOnShare)
                    Toggle("Quiet hours", isOn: $quietHours)
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
                }
                }
            }.formStyle(.grouped).tabItem { Label("Alerts", systemImage: "alarm") }
            EventsTab(store: store).tabItem { Label("Calendars", systemImage: "calendar") }
            RemindersTab(store: store).tabItem { Label("Reminders", systemImage: "checklist") }
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
    var nextIDs: Set<String> {
        let up = store.items.filter { !$0.isReminder && $0.time != "All day" && $0.sort > .now }
        guard let t = up.map(\.sort).min() else { return [] }
        return Set(up.filter { $0.sort == t }.map(\.id))
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
                Label("Check permission settings", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else if store.items.isEmpty {
                Text("Nothing today").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) { ForEach(store.items) { i in Row(i: i, next: nextIDs.contains(i.id), store: store) } }
            }
            Divider()
            if let v = store.update {
                Button("Update available: \(v)") { NSWorkspace.shared.open(URL(string: "https://github.com/bartek-sarul/todaybar/releases/latest/download/TodayBar.dmg")!) }
                    .buttonStyle(.plain).foregroundStyle(.blue)
            }
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(URL(string: "https://bodziec.gumroad.com/l/todaybar")!) } label: { Label("Support", systemImage: "heart") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Pay what you want")
            }
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
