import CoreGraphics
import Foundation

public struct PinCoreHotKey: Codable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct PinCoreProfile: Codable, Equatable {
    public let id: String
    public let bundleId: String
    public let hotKey: PinCoreHotKey?

    public init(id: String, bundleId: String, hotKey: PinCoreHotKey?) {
        self.id = id
        self.bundleId = bundleId
        self.hotKey = hotKey
    }
}

public struct PinCoreScreen: Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum PinCore {
    public static func deduplicatedProfilesByBundleID(_ profiles: [PinCoreProfile]) -> [PinCoreProfile] {
        var seen: Set<String> = []
        var result: [PinCoreProfile] = []
        for profile in profiles {
            if seen.contains(profile.bundleId) {
                continue
            }
            seen.insert(profile.bundleId)
            result.append(profile)
        }
        return result
    }

    public static func hotKeyConflict(
        setting: PinCoreHotKey,
        profileID: String,
        profiles: [PinCoreProfile]
    ) -> PinCoreProfile? {
        profiles.first { profile in
            profile.id != profileID && profile.hotKey == setting
        }
    }

    public static func frameBelowStatusItem(
        buttonFrame: CGRect,
        size: CGSize,
        visibleFrame: CGRect,
        padding: CGFloat = 8
    ) -> CGRect {
        var x = buttonFrame.midX - size.width / 2
        var y = visibleFrame.maxY - size.height - padding

        if x < visibleFrame.minX {
            x = visibleFrame.minX
        }
        if x + size.width > visibleFrame.maxX {
            x = visibleFrame.maxX - size.width
        }
        if y < visibleFrame.minY {
            y = visibleFrame.minY
        }
        if y + size.height > visibleFrame.maxY {
            y = visibleFrame.maxY - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    public static func screenContaining(
        point: CGPoint,
        screens: [PinCoreScreen]
    ) -> PinCoreScreen? {
        screens.first { $0.frame.contains(point) }
    }

    public static func fallbackMenuBarFrame(
        size: CGSize,
        mouseLocation: CGPoint,
        screens: [PinCoreScreen],
        padding: CGFloat = 12
    ) -> CGRect {
        let screen = screenContaining(point: mouseLocation, screens: screens) ?? screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        var x = visible.maxX - size.width - padding
        var y = visible.maxY - size.height - 8
        if x < visible.minX {
            x = visible.minX
        }
        if y < visible.minY {
            y = visible.minY
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
