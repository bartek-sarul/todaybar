import Foundation

func check(_ ok: Bool, _ msg: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(msg)"); exit(1) }
}

// quiet hours
check(inQuietHours(hour: 23, from: 22, to: 8), "wraps, late")
check(inQuietHours(hour: 3, from: 22, to: 8), "wraps, early")
check(!inQuietHours(hour: 12, from: 22, to: 8), "wraps, day")
check(inQuietHours(hour: 10, from: 9, to: 17), "same-day inside")
check(!inQuietHours(hour: 17, from: 9, to: 17), "same-day end exclusive")
check(!inQuietHours(hour: 5, from: 5, to: 5), "empty window")

// bar event
let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
func at(_ min: Double) -> Date { now.addingTimeInterval(min * 60) }
let running = at(-30), soon = at(10), later = at(60)
check(pickBarEvent([running, soon, later], start: { $0 }, now: now) == soon, "soon beats running")
check(pickBarEvent([running, later], start: { $0 }, now: now) == running, "running when nothing within 15m")
check(pickBarEvent([later], start: { $0 }, now: now) == later, "upcoming only")
check(pickBarEvent([running, at(15)], start: { $0 }, now: now) == at(15), "15m boundary inclusive")
check(pickBarEvent([Date](), start: { $0 }, now: now) == nil, "empty")

// bar title
check(barTitle(time: "9:00", name: "Standup", showTime: true, showName: true) == "9:00 Standup", "both")
check(barTitle(time: "9:00", name: "Standup", showTime: true, showName: false) == "9:00", "time only")
check(barTitle(time: "9:00", name: "Standup", showTime: false, showName: true) == "Standup", "name only")
check(barTitle(time: "9:00", name: "Standup", showTime: false, showName: false) == "", "neither")
check(barTitle(time: "", name: String(repeating: "x", count: 30), showTime: false, showName: true) == String(repeating: "x", count: 24) + "…", "truncate")

// snoozes
let s = activeSnoozes(["a": at(-1), "b": at(1)], now: now)
check(s.keys.sorted() == ["b"], "expired snooze dropped")

// update check
check(isNewer("v1.2.3", than: "1.2.2"), "patch newer")
check(isNewer("v1.10.0", than: "1.9.9"), "numeric not lexical")
check(!isNewer("v1.2.3", than: "1.2.3"), "equal")
check(!isNewer("v1.2.3", than: "1.3.0"), "older")
check(isNewer("v0.0.1", than: "0.0.0-dev"), "dev build suffix ignored")
check(isNewer("v1.2", than: "1.1.9"), "short")

print("ok")
