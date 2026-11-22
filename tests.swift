import Foundation

// Run with ./test.sh. Exits non-zero on the first failed check.
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// Gamma: light out = gammaMax^2.2, so it must equal the level asked for.
for level in [0.05, 0.1, 0.34, 0.5, 1.0] {
    check(near(pow(Core.gammaMax(level: level), 2.2), level, 1e-9), "gammaMax(\(level)) gives that share of light")
}
check(Core.gammaMax(level: 2) == 1 && Core.gammaMax(level: -1) == 0, "gammaMax clamps")

// Easing: starts at start, ends at end, halfway is the geometric mean, never overshoots.
check(near(Core.easeLevel(start: 0.8, end: 0.2, progress: 0), 0.8), "ease starts at start")
check(near(Core.easeLevel(start: 0.8, end: 0.2, progress: 1), 0.2), "ease ends at target")
check(near(Core.easeLevel(start: 0.8, end: 0.2, progress: 0.5), 0.4), "ease halfway is geometric mean")
check(near(Core.easeLevel(start: 0.8, end: 0.2, progress: 3), 0.2), "ease clamps past the end")

// Auto start window.
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 22))!
check(!Core.autoStartDue(now: start.addingTimeInterval(-60), start: start, lastRun: nil, calendar: cal), "not before the time")
check(Core.autoStartDue(now: start.addingTimeInterval(60), start: start, lastRun: nil, calendar: cal), "fires just after the time")
check(!Core.autoStartDue(now: start.addingTimeInterval(700), start: start, lastRun: nil, calendar: cal), "not after the 10 minute window")
check(!Core.autoStartDue(now: start.addingTimeInterval(60), start: start, lastRun: start, calendar: cal), "once per day")
check(Core.autoStartDue(now: start.addingTimeInterval(60), start: start, lastRun: start.addingTimeInterval(-86400), calendar: cal), "runs again the next day")

// Sunset against published times for 22 Nov 2026 , within 3 minutes.
func sunsetCheck(_ name: String, _ lat: Double, _ lon: Double, _ tz: String, _ h: Int, _ m: Int) {
    let zone = TimeZone(identifier: tz)!
    var c = Calendar(identifier: .gregorian); c.timeZone = zone
    let day = c.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!
    let expected = c.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: h, minute: m))!
    guard let s = Core.sunset(lat: lat, lon: lon, on: day, timeZone: zone) else { return check(false, "\(name) sunset exists") }
    check(abs(s.timeIntervalSince(expected)) < 180, "\(name) sunset \(s) near \(h):\(m)")
}
sunsetCheck("Berlin", 52.52, 13.405, "Europe/Berlin", 16, 5)
sunsetCheck("New York", 40.71, -74.01, "America/New_York", 16, 32)
sunsetCheck("Sydney", -33.87, 151.21, "Australia/Sydney", 19, 41)   // alpenglowapp.com: 19:38 on 18 Nov, +~1 min per day
sunsetCheck("Tokyo", 35.68, 139.69, "Asia/Tokyo", 16, 30)
check(Core.sunset(lat: 78.2, lon: 15.6, on: cal.date(from: DateComponents(year: 2026, month: 12, day: 21, hour: 12))!) == nil, "no sunset in polar night")

// Location guess: Berlin in winter is UTC+1, so 15° east.
let guess = Core.approximateLocation(timeZone: TimeZone(identifier: "Europe/Berlin")!, at: start)
check(near(guess.lon, 15), "time zone gives longitude")

// Conflicts.
check(Core.conflictingApp(runningBundleIDs: ["com.apple.finder", "org.herf.Flux"]) == "f.lux", "finds f.lux")
check(Core.conflictingApp(runningBundleIDs: ["com.apple.finder"]) == nil, "no false conflict")

// Warmth: neutral at 0, warm at 1 (red stays, blue drops most).
let neutral = Core.channelGains(kelvin: Core.kelvin(warmth: 0))
check(near(neutral.r, 1, 1e-6) && near(neutral.g, 1, 1e-6) && near(neutral.b, 1, 1e-6), "no warmth leaves colours alone")
let warm = Core.channelGains(kelvin: Core.kelvin(warmth: 1))
check(near(warm.r, 1, 1e-6) && warm.b < warm.g && warm.g < 1 && warm.b > 0.3, "full warmth: blue < green < red, blue not black")

print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
