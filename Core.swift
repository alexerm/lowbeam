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

extension Core {
    /// Warmth 0...1 maps 6500 K (neutral) to 2700 K (candle-like).
    static func kelvin(warmth w: Double) -> Double { 6500 - 3800 * min(max(w, 0), 1) }

    /// Channel gains for a colour temperature, relative to 6500 K (Tanner Helland's fit of the blackbody curve).
    static func channelGains(kelvin k: Double) -> (r: Double, g: Double, b: Double) {
        func raw(_ k: Double) -> (Double, Double, Double) {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
        }
        let n = raw(6500), c = raw(k)
        return (min(c.0 / n.0, 1), min(c.1 / n.1, 1), min(c.2 / n.2, 1))
    }
}

/// What the screen shows: the values a preset stores and a wind-down moves between.
struct Look: Codable, Equatable {
    var level: Double, gamma: Double, warmth: Double, blueCut: Double

    /// Wind-down point at progress p: light in log space, the rest linear.
    static func mix(_ a: Look, _ b: Look, _ p: Double) -> Look {
        let p = min(max(p, 0), 1)
        func lin(_ x: Double, _ y: Double) -> Double { x + (y - x) * p }
        return Look(level: Core.easeLevel(start: a.level, end: b.level, progress: p),
                    gamma: lin(a.gamma, b.gamma), warmth: lin(a.warmth, b.warmth), blueCut: lin(a.blueCut, b.blueCut))
    }

    func near(_ o: Look) -> Bool {
        abs(level - o.level) < 0.02 && abs(gamma - o.gamma) < 0.05 && abs(warmth - o.warmth) < 0.03 && abs(blueCut - o.blueCut) < 0.02
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var look: Look
    var keyboard: Bool

    static let defaults = [
        Preset(name: "Day", look: Look(level: 1, gamma: 1, warmth: 0, blueCut: 0), keyboard: true),
        Preset(name: "Reading", look: Look(level: 0.75, gamma: 1.3, warmth: 0, blueCut: 0.5), keyboard: false),
        Preset(name: "Night", look: Look(level: 0.5, gamma: 1.6, warmth: 0, blueCut: 0.75), keyboard: false),
    ]

    /// Looks shipped in 1.2.0 that made the screen too dark; a saved preset still on one moves to the new default.
    static let retired = ["Reading": Look(level: 0.45, gamma: 1.3, warmth: 0, blueCut: 0.5),
                          "Night": Look(level: 0.12, gamma: 1.8, warmth: 0, blueCut: 0.75)]
    static func migrate(_ list: [Preset]) -> [Preset] {
        list.map { p in
            var p = p
            if retired[p.name] == p.look, let new = defaults.first(where: { $0.name == p.name }) { p.look = new.look }
            if p.name == "Reading", p.look == defaults[1].look { p.keyboard = false }   // 1.2.0 shipped it with the light on
            return p
        }
    }
}

extension Core {
    /// The less-blue slider moves in four steps: none, −25%, −50%, −75%.
    static func blueStep(_ amount: Double) -> Double { (min(max(amount, 0), 1) * 3).rounded() * 0.25 }
}
