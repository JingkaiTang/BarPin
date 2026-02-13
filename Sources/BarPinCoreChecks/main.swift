import CoreGraphics
import Foundation

import BarPinCore

private struct CheckFailure: Error {
    let message: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(message: message)
    }
}

private func runChecks() throws {
    let profiles = [
        PinCoreProfile(id: "1", bundleId: "com.apple.Calendar", hotKey: nil),
        PinCoreProfile(id: "2", bundleId: "com.apple.Notes", hotKey: nil),
        PinCoreProfile(id: "3", bundleId: "com.apple.Calendar", hotKey: nil)
    ]
    let deduped = PinCore.deduplicatedProfilesByBundleID(profiles)
    try expect(deduped.map(\.id) == ["1", "2"], "dedup keeps first profile per bundleId")

    let hk = PinCoreHotKey(keyCode: 11, modifiers: 1179648)
    let conflict = PinCore.hotKeyConflict(
        setting: hk,
        profileID: "self",
        profiles: [
            PinCoreProfile(id: "self", bundleId: "com.apple.Calendar", hotKey: hk),
            PinCoreProfile(id: "other", bundleId: "com.apple.Notes", hotKey: hk)
        ]
    )
    try expect(conflict?.id == "other", "hotkey conflict detection")

    let frame = PinCore.frameBelowStatusItem(
        buttonFrame: CGRect(x: 1880, y: 1055, width: 40, height: 20),
        size: CGSize(width: 600, height: 400),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050)
    )
    try expect(frame.minX >= 0 && frame.maxX <= 1920, "frameBelowStatusItem x clamp")
    try expect(frame.minY >= 0 && frame.maxY <= 1050, "frameBelowStatusItem y clamp")

    let left = PinCoreScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 870)
    )
    let right = PinCoreScreen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1050)
    )
    let fallback = PinCore.fallbackMenuBarFrame(
        size: CGSize(width: 600, height: 400),
        mouseLocation: CGPoint(x: 2000, y: 600),
        screens: [left, right]
    )
    try expect(fallback.minX >= right.visibleFrame.minX && fallback.maxX <= right.visibleFrame.maxX, "fallback frame uses mouse screen x")
    try expect(fallback.minY >= right.visibleFrame.minY && fallback.maxY <= right.visibleFrame.maxY, "fallback frame uses mouse screen y")
}

do {
    try runChecks()
    print("BarPinCoreChecks PASS")
} catch let error as CheckFailure {
    fputs("BarPinCoreChecks FAIL: \(error.message)\n", stderr)
    exit(1)
} catch {
    fputs("BarPinCoreChecks FAIL: \(error)\n", stderr)
    exit(1)
}
