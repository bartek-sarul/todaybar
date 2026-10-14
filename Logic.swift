import Foundation

// Pure helpers, kept free of AppKit/EventKit so tests/main.swift can compile them alone.

/// Quiet window in whole hours; wraps past midnight when `from > to`.
func inQuietHours(hour: Int, from: Int, to: Int) -> Bool {
    from <= to ? (from..<to).contains(hour) : (hour >= from || hour < to)
}

/// Menu bar event: one starting within `window` beats one already running; else the earliest.
/// `sorted` must be ordered by start and exclude finished events.
func pickBarEvent<T>(_ sorted: [T], start: (T) -> Date, now: Date, window: TimeInterval = 900) -> T? {
    sorted.first { start($0) > now && start($0) <= now.addingTimeInterval(window) } ?? sorted.first
}

func barTitle(time: String, name: String, showTime: Bool, showName: Bool, maxName: Int = 24) -> String {
    [showTime ? time : "", showName ? (name.count > maxName ? name.prefix(maxName) + "…" : name) : ""]
        .filter { !$0.isEmpty }.joined(separator: " ")
}

func activeSnoozes(_ s: [String: Date], now: Date) -> [String: Date] { s.filter { $0.value > now } }
