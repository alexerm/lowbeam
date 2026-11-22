import Cocoa
import SwiftUI
import CoreLocation
import ServiceManagement

// MARK: - Model

enum AutoStart: String { case off, sunset, time }
enum ColourStyle: String { case warm, blue }

final class Dimmer: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled"); apply() } }
    @Published var level: Double { didSet { d.set(level, forKey: "level"); apply() } }      // share of light, 0.05...1
    @Published var gamma: Double { didSet { d.set(gamma, forKey: "gamma"); apply() } }      // 1...2.5
    @Published var warmth: Double { didSet { d.set(warmth, forKey: "warmth"); apply() } }   // 0 neutral ... 1 = 2700 K
    @Published var blueCut: Double { didSet { d.set(blueCut, forKey: "blueCut"); apply() } }   // share of blue removed
    @Published var style: ColourStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var presets: [Preset] { didSet { d.set(try? JSONEncoder().encode(presets), forKey: "presets") } }
    @Published var windTarget: String { didSet { d.set(windTarget, forKey: "windTarget") } }   // preset id
    @Published var minutes: Int { didSet { d.set(minutes, forKey: "minutes") } }
    @Published var auto: AutoStart { didSet { d.set(auto.rawValue, forKey: "auto"); if auto == .sunset { locate() } } }
    @Published var autoKind: AutoStart { didSet { d.set(autoKind.rawValue, forKey: "autoKind") } }   // sunset or time, kept while off
    @Published var startMinute: Int { didSet { d.set(startMinute, forKey: "startMinute") } } // minutes after midnight
    /// Extra dimming per app (bundle id → share removed), against the flash from a dark app to a bright one.
    @Published var appDim: [String: Double] { didSet { d.set(appDim, forKey: "appDim"); apply() } }
    @Published private(set) var frontApp: NSRunningApplication?
    @Published var sunset: Date?
    @Published var sunsetIsGuess = false          // location off: sunset from the time zone
    @Published var conflict: String?              // another app that writes the gamma table
    @Published private(set) var easeEnd: Date?
    @Published private(set) var easeProgress = 0.0

    let keyboard = KeyboardLight()
    @Published private(set) var keyboardOn = false

    func refreshKeyboard() { keyboardOn = keyboard.level > 0 }

    /// Off remembers the level; on brings it back (KeyLight's very low level if none was saved).
    func setKeyboard(on: Bool) {
        guard keyboard.available else { return }
        if on {
            if keyboard.level == 0 { keyboard.set(d.object(forKey: "keyboardLevel") as? Float ?? 0.0003) }
        } else {
            let now = keyboard.level
            if now > 0 { d.set(now, forKey: "keyboardLevel") }
            keyboard.set(0)
        }
        refreshKeyboard()
    }

    private var easeTimer: Timer?
    private let loc = CLLocationManager()

    override init() {
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        level = d.object(forKey: "level") as? Double ?? 1
        gamma = d.object(forKey: "gamma") as? Double ?? 1
        warmth = d.object(forKey: "warmth") as? Double ?? 0
        blueCut = d.object(forKey: "blueCut") as? Double ?? 0
        style = ColourStyle(rawValue: d.string(forKey: "style") ?? "") ?? .blue
        let saved = (d.data(forKey: "presets")).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) }
        presets = saved ?? Preset.defaults
        windTarget = d.string(forKey: "windTarget") ?? (saved ?? Preset.defaults).last!.id
        minutes = d.object(forKey: "minutes") as? Int ?? 30
        auto = AutoStart(rawValue: d.string(forKey: "auto") ?? "") ?? .off
        autoKind = AutoStart(rawValue: d.string(forKey: "autoKind") ?? "") ?? .sunset
        startMinute = d.object(forKey: "startMinute") as? Int ?? 22 * 60
        appDim = d.dictionary(forKey: "appDim") as? [String: Double] ?? [:]
        super.init()
        if saved == nil { presets = Preset.defaults; windTarget = presets.last!.id }
        if auto != .off { autoKind = auto }
        loc.delegate = self
        updateSunset()
        if auto == .sunset { locate() }
        frontApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        // Gamma resets on wake, display change and some app launches; re-apply.
        NotificationCenter.default.addObserver(self, selector: #selector(apply), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(apply), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.apply() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.checkAutoStart(); self?.checkConflict() }
        checkConflict()
        // Open at login is on by default; one path only (SMAppService), so the checkbox tells the truth.
        if d.object(forKey: "loginSet") == nil { d.set(true, forKey: "loginSet"); try? SMAppService.mainApp.register() }
        apply()
    }

    /// The app in front, ignoring Dimmer itself (the popover makes Dimmer active).
    @objc private func appActivated(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              a.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        frontApp = a
        apply()   // at once: the new app's first frame is the flash
    }

    var frontDim: Double { frontApp?.bundleIdentifier.flatMap { appDim[$0] } ?? 0 }
    func setFrontDim(_ v: Double) {
        guard let id = frontApp?.bundleIdentifier else { return }
        appDim[id] = v > 0 ? v : nil
    }

    @objc func apply() {
        let lit = level * (1 - frontDim)
        if !enabled || (lit >= 0.999 && gamma <= 1.001 && warmth <= 0.001 && blueCut <= 0.001) { CGDisplayRestoreColorSyncSettings(); return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        // Exponent > 1 dims darks faster than brights.
        let m = CGGammaValue(Core.gammaMax(level: lit)), g = CGGammaValue(gamma)
        let c = Core.channelGains(kelvin: Core.kelvin(warmth: warmth))
        let r = m * CGGammaValue(c.r), gr = m * CGGammaValue(c.g), b = m * CGGammaValue(c.b * (1 - blueCut))
        for id in ids.prefix(Int(n)) { CGSetDisplayTransferByFormula(id, 0, r, g, 0, gr, g, 0, b, g) }
    }

    // MARK: Looks and presets

    var look: Look {
        get { Look(level: level, gamma: gamma, warmth: warmth, blueCut: blueCut) }
        set { level = newValue.level; gamma = newValue.gamma; warmth = newValue.warmth; blueCut = newValue.blueCut }
    }

    /// The colour slider: one amount, read as warmth or as blue cut by the style.
    var colour: Double { style == .warm ? warmth : blueCut / 0.75 }
    func setColour(_ v: Double) {
        stopEase()
        if style == .warm { warmth = v; blueCut = 0 } else { blueCut = Core.blueStep(v); warmth = 0 }
    }
    func setStyle(_ s: ColourStyle) {
        let v = colour; style = s; setColour(v)
    }

    var currentPreset: Preset? { presets.first { $0.look.near(look) } }
    var windPreset: Preset { presets.first { $0.id == windTarget } ?? presets.last ?? Preset.defaults[2] }

    func use(_ p: Preset) {
        stopEase(); enabled = true
        look = p.look
        if p.look.warmth > 0.001 { style = .warm } else if p.look.blueCut > 0.001 { style = .blue }
        setKeyboard(on: p.keyboard)
    }
    func saveCurrent(as name: String) {
        let p = Preset(name: name, look: look, keyboard: keyboard.available ? keyboardOn : true)
        presets.append(p)
    }
    func update(_ p: Preset) {
        guard let i = presets.firstIndex(of: p) else { return }
        presets[i].look = look
        if keyboard.available { presets[i].keyboard = keyboardOn }
    }
    func rename(_ p: Preset, to name: String) {
        guard let i = presets.firstIndex(of: p) else { return }
        presets[i].name = name
    }
    func delete(_ p: Preset) {
        guard presets.count > 1 else { return }
        presets.removeAll { $0.id == p.id }
        if windTarget == p.id { windTarget = presets.last!.id }
    }

    // MARK: Wind down

    var easing: Bool { easeTimer != nil }

    func startEase() {
        stopEase()
        let target = windPreset, from = look, total = Double(minutes * 60)
        guard !from.near(target.look) else { setKeyboard(on: target.keyboard); return }
        enabled = true
        if target.look.warmth > 0.001 { style = .warm } else if target.look.blueCut > 0.001 { style = .blue }
        let began = Date()
        easeEnd = began.addingTimeInterval(total)
        easeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = min(Date().timeIntervalSince(began) / total, 1)
            self.easeProgress = p
            self.look = Look.mix(from, target.look, p)
            if p >= 1 { self.stopEase(); self.setKeyboard(on: target.keyboard) }
        }
    }

    func stopEase() { easeTimer?.invalidate(); easeTimer = nil; easeEnd = nil; easeProgress = 0 }

    // MARK: Auto start

    var autoOn: Bool {
        get { auto != .off }
        set { auto = newValue ? autoKind : .off }
    }
    func setAutoKind(_ k: AutoStart) { autoKind = k; auto = k }

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
    static let pop = Color(hex: 0x1C1C1F), pop2 = Color(hex: 0x26262A), pop3 = Color(hex: 0x222225), line = Color(hex: 0x34343A)
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

/// A row of equal buttons, one selected.
struct Segments<T: Equatable>: View {
    let options: [(T, String)]
    let selected: T
    var height: CGFloat = 28
    let pick: (T) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                let (v, label) = options[i], on = v == selected
                Button { pick(v) } label: {
                    Text(label).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? .ink : .ink2)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.amberDim : Color.pop2))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.amber : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Text prompt for a preset name. Nil when cancelled or empty.
func askName(_ title: String, _ initial: String) -> String? {
    let a = NSAlert(); a.messageText = title
    a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.stringValue = initial
    a.accessoryView = f; a.window.initialFirstResponder = f
    NSApp.activate(ignoringOtherApps: true)
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let s = f.stringValue.trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}

struct Popover: View {
    @ObservedObject var m: Dimmer

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func clock(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private var contrastWord: String {
        switch m.gamma { case ..<1.05: return "Normal"; case ..<1.5: return "Soft"; case ..<2: return "Crisp"; default: return "Strong" }
    }
    private var colourValue: String {
        if m.style == .warm { return "\(Int(Core.kelvin(warmth: m.warmth).rounded())) K" }
        return m.blueCut < 0.01 ? "Full blue" : "−\(Int((m.blueCut * 100).rounded()))% blue"
    }

    private func chip(_ p: Preset) -> some View {
        let on = m.currentPreset?.id == p.id
        return Button { m.use(p) } label: {
            Text(p.name).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundColor(on ? .ink : .ink2)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(on ? Color.amberDim : Color.pop2))
                .overlay(Capsule().strokeBorder(on ? Color.amber : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Update to current") { m.update(p) }
            Button("Rename…") { if let n = askName("Rename preset", p.name) { m.rename(p, to: n) } }
            Divider()
            Button("Delete") { m.delete(p) }.disabled(m.presets.count < 2)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dimmer").fontWeight(.semibold)
                Spacer()
                Toggle("", isOn: $m.enabled).toggleStyle(.switch).tint(.amber).labelsHidden().controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(m.presets) { chip($0) }
                    Button {
                        if let n = askName("Save preset", "Preset \(m.presets.count + 1)") { m.saveCurrent(as: n) }
                    } label: {
                        Label("Save", systemImage: "plus").font(.system(size: 12)).foregroundColor(.ink2)
                            .padding(.horizontal, 12).frame(height: 28)
                            .overlay(Capsule().strokeBorder(Color.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).help("Save the current look as a preset. Right-click a preset to update, rename or delete it.")
                }
            }

            CapsuleSlider(icon: "sun.min", name: "Brightness", value: pct(m.level), fraction: Binding(
                get: { (m.level - 0.05) / 0.95 },
                set: { m.stopEase(); m.level = 0.05 + $0 * 0.95 }))

            CapsuleSlider(icon: "circle.lefthalf.filled", name: "Contrast", value: contrastWord, fraction: Binding(
                get: { (m.gamma - 1) / 1.5 }, set: { m.stopEase(); m.gamma = 1 + $0 * 1.5 }))

            VStack(spacing: 8) {
                Segments(options: [(ColourStyle.blue, "Less blue"), (.warm, "Warm")], selected: m.style) { m.setStyle($0) }
                CapsuleSlider(icon: m.style == .warm ? "flame" : "drop", name: "Colour", value: colourValue, fraction: Binding(
                    get: { m.colour }, set: { m.setColour($0) }))
            }

            if m.keyboard.available {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard").foregroundColor(.amber).frame(width: 18)
                    Text("Keyboard light")
                    Spacer()
                    Toggle("", isOn: Binding(get: { m.keyboardOn }, set: { m.setKeyboard(on: $0) }))
                        .toggleStyle(.switch).tint(.amber).labelsHidden().controlSize(.small)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.pop2))
            }

            if let app = m.frontApp {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                        Text("Extra dim in \(app.localizedName ?? "this app")").foregroundColor(.ink2)
                    }.font(.system(size: 12))
                    Segments(options: [(0.0, "Same"), (0.25, "−25%"), (0.5, "−50%"), (0.75, "−75%")],
                             selected: m.frontDim) { m.setFrontDim($0) }
                }
            }

            Divider().overlay(Color.line)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "moon").foregroundColor(.amber).frame(width: 18)
                    Text("Wind down to")
                    Spacer()
                    Menu {
                        ForEach(m.presets) { p in Button(p.name) { m.windTarget = p.id } }
                    } label: { Text(m.windPreset.name).fontWeight(.semibold).foregroundColor(.ink) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                Segments(options: [(10, "10 min"), (30, "30 min"), (60, "1 hour")], selected: m.minutes, height: 32) {
                    m.minutes = $0; m.startEase()
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
                            Text("Reaches \(m.windPreset.name) at \(clock(m.easeEnd))").foregroundColor(.ink2)
                            Spacer()
                            Button("Stop") { m.stopEase() }.buttonStyle(.plain).foregroundColor(.amber)
                        }.font(.system(size: 12))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Start on its own")
                        Spacer()
                        Toggle("", isOn: Binding(get: { m.autoOn }, set: { m.autoOn = $0 }))
                            .toggleStyle(.switch).tint(.amber).labelsHidden().controlSize(.small)
                    }
                    if m.autoOn {
                        Segments(options: [(AutoStart.sunset, "At sunset"), (.time, "At a set time")], selected: m.auto) { m.setAutoKind($0) }
                        HStack {
                            if m.auto == .sunset {
                                Image(systemName: "sunset").foregroundColor(.amber)
                                Text("Today \(m.sunsetIsGuess ? "about " : "")\(clock(m.sunset))").foregroundColor(.ink2)
                            } else {
                                Text("Starts at").foregroundColor(.ink2)
                                Spacer()
                                DatePicker("", selection: Binding(
                                    get: { Calendar.current.date(bySettingHour: m.startMinute / 60, minute: m.startMinute % 60, second: 0, of: Date())! },
                                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); m.startMinute = c.hour! * 60 + c.minute! }),
                                    displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                            }
                            Spacer()
                        }.font(.system(size: 12)).frame(minHeight: 22)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.pop3))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.line))
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
        model.refreshKeyboard()
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
