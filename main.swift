import Cocoa
import SwiftUI
import CoreLocation
import ServiceManagement

// MARK: - Model

enum AutoStart: String { case off, sunset, time }

final class Dimmer: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled"); apply() } }
    @Published var level: Double { didSet { d.set(level, forKey: "level"); apply() } }      // share of light, 0.05...1
    @Published var gamma: Double { didSet { d.set(gamma, forKey: "gamma"); apply() } }      // 1...2.5
    @Published var warmth: Double { didSet { d.set(warmth, forKey: "warmth"); apply() } }   // 0 neutral ... 1 = 2700 K
    @Published var warmthTarget: Double { didSet { d.set(warmthTarget, forKey: "warmthTarget") } }
    @Published var floor: Double { didSet { d.set(floor, forKey: "floor") } }   // wind-down target; never limits the slider
    @Published var minutes: Int { didSet { d.set(minutes, forKey: "minutes") } }
    @Published var auto: AutoStart { didSet { d.set(auto.rawValue, forKey: "auto"); if auto == .sunset { locate() } } }
    @Published var startMinute: Int { didSet { d.set(startMinute, forKey: "startMinute") } } // minutes after midnight
    @Published var sunset: Date?
    @Published var sunsetIsGuess = false          // location off: sunset from the time zone
    @Published var conflict: String?              // another app that writes the gamma table
    @Published private(set) var easeEnd: Date?
    @Published private(set) var easeProgress = 0.0

    private var easeTimer: Timer?
    private let loc = CLLocationManager()

    override init() {
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        level = d.object(forKey: "level") as? Double ?? 1
        gamma = d.object(forKey: "gamma") as? Double ?? 1
        warmth = d.object(forKey: "warmth") as? Double ?? 0
        warmthTarget = d.object(forKey: "warmthTarget") as? Double ?? 0.6
        floor = d.object(forKey: "floor") as? Double ?? 0.05
        minutes = d.object(forKey: "minutes") as? Int ?? 30
        auto = AutoStart(rawValue: d.string(forKey: "auto") ?? "") ?? .off
        startMinute = d.object(forKey: "startMinute") as? Int ?? 22 * 60
        super.init()
        loc.delegate = self
        updateSunset()
        if auto == .sunset { locate() }
        // Gamma resets on wake, display change and some app launches; re-apply.
        NotificationCenter.default.addObserver(self, selector: #selector(apply), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(apply), name: NSWorkspace.screensDidWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.apply() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkAutoStart(); self?.checkConflict() }
        checkConflict()
        // Open at login is on by default; one path only (SMAppService), so the checkbox tells the truth.
        if d.object(forKey: "loginSet") == nil { d.set(true, forKey: "loginSet"); try? SMAppService.mainApp.register() }
        apply()
    }

    @objc func apply() {
        if !enabled || (level >= 0.999 && gamma <= 1.001 && warmth <= 0.001) { CGDisplayRestoreColorSyncSettings(); return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        // Exponent > 1 dims darks faster than brights.
        let m = CGGammaValue(Core.gammaMax(level: level)), g = CGGammaValue(gamma)
        let c = Core.channelGains(kelvin: Core.kelvin(warmth: warmth))
        let r = m * CGGammaValue(c.r), gr = m * CGGammaValue(c.g), b = m * CGGammaValue(c.b)
        for id in ids.prefix(Int(n)) { CGSetDisplayTransferByFormula(id, 0, r, g, 0, gr, g, 0, b, g) }
    }

    // MARK: Wind down

    var easing: Bool { easeTimer != nil }

    func startEase() {
        stopEase()
        let start = level, end = min(floor, level), total = Double(minutes * 60)
        let w0 = warmth, w1 = max(warmthTarget, warmth)
        guard start > end + 0.001 || w1 > w0 + 0.001 else { return }
        enabled = true
        let began = Date()
        easeEnd = began.addingTimeInterval(total)
        easeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = min(Date().timeIntervalSince(began) / total, 1)
            self.easeProgress = p
            self.level = Core.easeLevel(start: start, end: end, progress: p)
            self.warmth = w0 + (w1 - w0) * p
            if p >= 1 { self.stopEase() }
        }
    }

    func stopEase() { easeTimer?.invalidate(); easeTimer = nil; easeEnd = nil; easeProgress = 0 }

    // MARK: Auto start

    var nextStart: Date? {
        let cal = Calendar.current
        switch auto {
        case .off: return nil
        case .time: return cal.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: Date())
        case .sunset: return sunset
        }
    }

    private func checkAutoStart() {
        if auto == .sunset { updateSunset() }
        guard let t = nextStart, !easing else { return }
        if Core.autoStartDue(now: Date(), start: t, lastRun: d.object(forKey: "lastAuto") as? Date) {
            d.set(Date(), forKey: "lastAuto")
            startEase()
        }
    }

    private func checkConflict() {
        conflict = Core.conflictingApp(runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func updateSunset() {
        if let lat = d.object(forKey: "lat") as? Double, let lon = d.object(forKey: "lon") as? Double {
            sunset = Core.sunset(lat: lat, lon: lon, on: Date()); sunsetIsGuess = false
        } else {
            let g = Core.approximateLocation()
            sunset = Core.sunset(lat: g.lat, lon: g.lon, on: Date()); sunsetIsGuess = true
        }
    }

    private func locate() {
        loc.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        loc.requestWhenInUseAuthorization()
        loc.requestLocation()
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        d.set(c.latitude, forKey: "lat"); d.set(c.longitude, forKey: "lon")
        updateSunset()
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}

    // MARK: Login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); objectWillChange.send() }
    }
}

// MARK: - Look

extension Color {
    static let pop = Color(hex: 0x1C1C1F), pop2 = Color(hex: 0x26262A), line = Color(hex: 0x34343A)
    static let ink = Color(hex: 0xECE9E4), ink2 = Color(hex: 0xA19D97)
    static let amber = Color(hex: 0xF2A54A), amberDim = Color(hex: 0x5A4127)
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}

struct CapsuleSlider: View {
    let icon: String, name: String, value: String
    @Binding var fraction: Double   // 0...1 of the track
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.pop2
                Color.amberDim.frame(width: max(0, geo.size.width * fraction))
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundColor(.amber).frame(width: 18)
                    Text(name).foregroundColor(.ink)
                    Spacer()
                    Text(value).fontWeight(.semibold).monospacedDigit().foregroundColor(.ink)
                }.padding(.horizontal, 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                fraction = min(max(v.location.x / geo.size.width, 0), 1)
            })
        }
        .frame(height: 44)
        .font(.system(size: 13))
    }
}

struct Popover: View {
    @ObservedObject var m: Dimmer
    @State private var pickTime = false

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func clock(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private var contrastWord: String {
        switch m.gamma { case ..<1.05: return "Normal"; case ..<1.5: return "Soft"; case ..<2: return "Crisp"; default: return "Strong" }
    }
    private var autoLabel: String {
        switch m.auto {
        case .off: return "Off"
        case .sunset: return "At sunset · \(m.sunsetIsGuess ? "about " : "")\(clock(m.sunset))"
        case .time: return "At \(clock(m.nextStart))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Dimmer").fontWeight(.semibold)
                Spacer()
                Toggle("", isOn: $m.enabled).toggleStyle(.switch).tint(.amber).labelsHidden().controlSize(.small)
            }

            CapsuleSlider(icon: "sun.min", name: "Brightness", value: pct(m.level), fraction: Binding(
                get: { (m.level - 0.05) / 0.95 },
                set: { m.stopEase(); m.level = 0.05 + $0 * 0.95 }))

            CapsuleSlider(icon: "circle.lefthalf.filled", name: "Contrast", value: contrastWord, fraction: Binding(
                get: { (m.gamma - 1) / 1.5 }, set: { m.gamma = 1 + $0 * 1.5 }))

            CapsuleSlider(icon: "flame", name: "Warmth", value: "\(Int(Core.kelvin(warmth: m.warmth).rounded())) K", fraction: Binding(
                get: { m.warmth }, set: { m.stopEase(); m.warmth = $0 }))

            Divider().overlay(Color.line)

            VStack(alignment: .leading, spacing: 10) {
                CapsuleSlider(icon: "moon", name: "Wind down to", value: pct(m.floor), fraction: Binding(
                    get: { (m.floor - 0.05) / 0.95 },
                    set: { m.floor = 0.05 + $0 * 0.95 }))
                CapsuleSlider(icon: "flame", name: "Warm up to", value: "\(Int(Core.kelvin(warmth: m.warmthTarget).rounded())) K", fraction: Binding(
                    get: { m.warmthTarget }, set: { m.warmthTarget = $0 }))
                HStack(spacing: 6) {
                    ForEach([(10, "10 min"), (30, "30 min"), (60, "1 hour")], id: \.0) { mins, label in
                        let on = m.minutes == mins
                        Button { m.minutes = mins; m.startEase() } label: {
                            Text(label).font(.system(size: 12, weight: on ? .semibold : .regular))
                                .foregroundColor(on ? .ink : .ink2)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.amberDim : Color.pop2))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.amber : .clear))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("Start on its own").foregroundColor(.ink2)
                    Spacer()
                    Menu {
                        Button("Off") { m.auto = .off }
                        Button("At sunset") { m.auto = .sunset }
                        Button("At a set time…") { m.auto = .time; pickTime = true }
                    } label: {
                        HStack(spacing: 4) {
                            if m.auto == .sunset { Image(systemName: "sunset").foregroundColor(.amber) }
                            Text(autoLabel).fontWeight(.medium).foregroundColor(.ink)
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.pop2))

                if pickTime || m.auto == .time {
                    DatePicker("Start at", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: m.startMinute / 60, minute: m.startMinute % 60, second: 0, of: Date())! },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); m.startMinute = c.hour! * 60 + c.minute! }),
                        displayedComponents: .hourAndMinute)
                        .font(.system(size: 12)).foregroundColor(.ink2)
                }

                if m.easing {
                    VStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.pop2)
                                RoundedRectangle(cornerRadius: 2).fill(Color.amber).frame(width: g.size.width * m.easeProgress)
                            }
                        }.frame(height: 4)
                        HStack {
                            Text("Reaches \(pct(m.floor)) at \(clock(m.easeEnd))").foregroundColor(.ink2)
                            Spacer()
                            Button("Stop") { m.stopEase() }.buttonStyle(.plain).foregroundColor(.amber)
                        }.font(.system(size: 12))
                    }
                }
            }

            if let other = m.conflict {
                Text("\(other) also changes screen colors, so the two reset each other. Quit \(other) while Dimmer is on.")
                    .font(.system(size: 12)).foregroundColor(.amber).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.line)

            HStack {
                Toggle("Open at login", isOn: Binding(get: { m.opensAtLogin }, set: { m.opensAtLogin = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }.font(.system(size: 12)).foregroundColor(.ink2)
        }
        .font(.system(size: 13))
        .foregroundColor(.ink)
        .padding(16)
        .frame(width: 300)
        .background(Color.pop)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let model = Dimmer()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.image = Self.menuIcon()
        item.button?.action = #selector(toggle)
        item.button?.target = self
        popover.behavior = .transient   // closes on a click outside and on Esc
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: Popover(m: model))
        // Without a real content size the popover guesses its height and macOS pushes it up over the menu bar.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() } }
    }
    // Same mark as the app icon: half-lit disc, rays that fade and shorten clockwise.
    static func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let c = CGPoint(x: 9, y: 9)
            ctx.setLineCap(.round); ctx.setLineWidth(1.5)
            for i in 0..<8 {
                let t = CGFloat(i) / 7, a = CGFloat.pi / 2 - CGFloat(i) * .pi / 4
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(1 - 0.7 * t).cgColor)
                let r1 = 6.6 + 2.0 * (1 - 0.6 * t)
                ctx.move(to: CGPoint(x: c.x + 6.2 * cos(a), y: c.y + 6.2 * sin(a)))
                ctx.addLine(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
                ctx.strokePath()
            }
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1.4)
            ctx.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)); ctx.strokePath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.move(to: c); ctx.addArc(center: c, radius: 4, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
            ctx.closePath(); ctx.fillPath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Dimmer"
        return img
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        popover.contentSize = popover.contentViewController!.view.fittingSize
        popover.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ n: Notification) { CGDisplayRestoreColorSyncSettings() }
}

let app = NSApplication.shared
let delegate = App(); app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
