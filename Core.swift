import Foundation

// Pure logic, kept apart from the UI so tests.swift can check it.
enum Core {
    /// Top of the gamma ramp for a share of light. The panel's light is about signal^2.2,
    /// so scaling the signal linearly would crush dark greys.
    static func gammaMax(level: Double) -> Double { pow(min(max(level, 0), 1), 1 / 2.2) }

    /// Wind-down level at progress p (0...1). Log space: each step is the same perceived change.
    static func easeLevel(start: Double, end: Double, progress p: Double) -> Double {
        start * pow(end / start, min(max(p, 0), 1))
    }

    /// The automatic start fires once a day, within 10 minutes after its time
    /// (covers a Mac that wakes a little late), and not again on a day it already ran.
    static func autoStartDue(now: Date, start: Date, lastRun: Date?, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        if let lastRun, lastRun >= today { return false }
        return now >= start && now.timeIntervalSince(start) < 600
    }

    /// Location guess from the time zone, for when location access is off.
    /// Longitude follows the UTC offset; latitude 45° is a middle value for most users.
    static func approximateLocation(timeZone: TimeZone = .current, at date: Date = Date()) -> (lat: Double, lon: Double) {
        let offset = Double(timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date))) / 3600
        return (45, offset * 15)
    }

    /// NOAA sunset approximation, accurate to a minute or two. Nil during polar day or night.
    static func sunset(lat: Double, lon: Double, on date: Date, timeZone: TimeZone = .current) -> Date? {
        var local = Calendar(identifier: .gregorian); local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let n = Double(local.ordinality(of: .day, in: .year, for: date) ?? 1)
        let rad = Double.pi / 180
        let gm = 2 * Double.pi / 365 * (n - 1)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(gm) - 0.032077 * sin(gm) - 0.014615 * cos(2 * gm) - 0.040849 * sin(2 * gm))
        let decl = 0.006918 - 0.399912 * cos(gm) + 0.070257 * sin(gm) - 0.006758 * cos(2 * gm) + 0.000907 * sin(2 * gm) - 0.002697 * cos(3 * gm) + 0.00148 * sin(3 * gm)
        let cosH = cos(90.833 * rad) / (cos(lat * rad) * cos(decl)) - tan(lat * rad) * tan(decl)
        guard abs(cosH) <= 1 else { return nil }
        let ha = acos(cosH) / rad
        let utcMin = 720 - 4 * (lon - ha) - eq
        guard let midnightUTC = utc.date(from: local.dateComponents([.year, .month, .day], from: date)) else { return nil }
        return midnightUTC.addingTimeInterval(utcMin * 60)
    }

    /// Apps that also write the display gamma table. Running together, each one resets the other.
    static let gammaApps: [String: String] = [
        "org.herf.Flux": "f.lux",
        "fyi.lunar.Lunar": "Lunar",
        "pro.betterdisplay.BetterDisplay": "BetterDisplay",
        "com.monitorcontrol.MonitorControl": "MonitorControl",
        "com.hegenberg.Iris": "Iris",
        "com.nightowl.app": "NightOwl",
        "com.dimmerapp.QuickShade": "QuickShade",
    ]

    static func conflictingApp(runningBundleIDs: [String]) -> String? {
        runningBundleIDs.lazy.compactMap { gammaApps[$0] }.first
    }
}
