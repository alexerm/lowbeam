import Foundation

/// Keyboard backlight through CoreBrightness's private KeyboardBrightnessClient (from KeyLight).
/// Every call is optional: on a Mac without a backlit keyboard, `available` is false and nothing happens.
final class KeyboardLight {
    private let client: NSObject?
    private let ids: [UInt64]
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias Auto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private let autoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")

    init() {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { client = nil; ids = []; return }
        let c = type.init()
        let raw = c.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs"))
            ? c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() : nil
        client = c
        ids = ((raw as? [NSNumber]) ?? []).map(\.uint64Value)
    }

    var available: Bool {
        guard let client, !ids.isEmpty else { return false }
        return client.responds(to: getSel) && client.responds(to: setSel) && client.responds(to: autoSel)
    }

    var level: Float {
        guard available, let client, let id = ids.first else { return 0 }
        return unsafeBitCast(client.method(for: getSel), to: Get.self)(client, getSel, id)
    }

    /// Sets the level on every backlit keyboard and turns automatic keyboard brightness off,
    /// so the ambient light sensor does not switch it back on.
    func set(_ v: Float) {
        guard available, let client else { return }
        let s = unsafeBitCast(client.method(for: setSel), to: Set.self)
        let a = unsafeBitCast(client.method(for: autoSel), to: Auto.self)
        for id in ids { _ = a(client, autoSel, false, id); _ = s(client, setSel, v, id) }
    }
}
