import AppKit
import ApplicationServices
import Carbon

private enum DefaultsKeys {
    static let pinProfiles = "pinProfiles"
    static let debugPlacement = "debugPlacement"
    static let uiLanguage = "uiLanguage"

    // Legacy keys from single-pin versions.
    static let targetAppPath = "targetAppPath"
    static let targetAppBundleId = "targetAppBundleId"
    static let targetAppDisplayName = "targetAppDisplayName"
    static let useAppIcon = "useAppIcon"
    static let useTemplateIcon = "useTemplateIcon"
    static let hotKeyKeyCode = "hotKeyKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
}

struct TargetApp {
    let url: URL
    let bundleId: String
    let displayName: String
}

enum UILanguage: String {
    case english = "en"
    case chinese = "zh"
}

struct HotKeySetting: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}

struct PinProfile: Codable, Equatable {
    var id: String
    var appPath: String
    var bundleId: String
    var displayName: String
    var useAppIcon: Bool
    var useTemplateIcon: Bool
    var hotKey: HotKeySetting?

    var targetApp: TargetApp {
        TargetApp(url: URL(fileURLWithPath: appPath), bundleId: bundleId, displayName: displayName)
    }
}

private final class HotKeyCaptureWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private final class HotKeyCaptureView: NSView {
    private let titleLabel: NSTextField
    private let hintLabel: NSTextField
    private let helpLabel: NSTextField
    private let invalidHint: String
    private let formatter: (HotKeySetting) -> String
    private let modifierMapper: (NSEvent.ModifierFlags) -> UInt32
    private let validator: (HotKeySetting) -> Bool
    private let onCapture: (HotKeySetting?) -> Void

    init(frame: CGRect,
         title: String,
         hint: String,
         help: String,
         invalidHint: String,
         formatter: @escaping (HotKeySetting) -> String,
         modifierMapper: @escaping (NSEvent.ModifierFlags) -> UInt32,
         validator: @escaping (HotKeySetting) -> Bool,
         onCapture: @escaping (HotKeySetting?) -> Void) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.hintLabel = NSTextField(labelWithString: hint)
        self.helpLabel = NSTextField(labelWithString: help)
        self.invalidHint = invalidHint
        self.formatter = formatter
        self.modifierMapper = modifierMapper
        self.validator = validator
        self.onCapture = onCapture
        super.init(frame: frame)

        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        hintLabel.font = NSFont.systemFont(ofSize: 13)
        helpLabel.font = NSFont.systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, hintLabel, helpLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCapture(nil)
            return
        }
        if isModifierKey(event.keyCode) {
            return
        }

        let modifiers = modifierMapper(event.modifierFlags)
        let setting = HotKeySetting(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if !validator(setting) {
            hintLabel.stringValue = invalidHint
            NSSound.beep()
            return
        }
        hintLabel.stringValue = formatter(setting)
        onCapture(setting)
    }

    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
             kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl,
             kVK_Function:
            return true
        default:
            return false
        }
    }
}

private extension String {
    var fourCharCode: OSType {
        var result: OSType = 0
        for scalar in utf8 {
            result = (result << 8) + OSType(scalar)
        }
        return result
    }
}

private final class PinRuntime {
    private unowned let owner: AppDelegate
    private(set) var profile: PinProfile

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var toggleItem: NSMenuItem!
    private var manageItem: NSMenuItem!
    private var useAppIconItem: NSMenuItem!
    private var iconStyleItem: NSMenuItem!
    private var hotKeyInfoItem: NSMenuItem!
    private var setHotKeyItem: NSMenuItem!
    private var clearHotKeyItem: NSMenuItem!
    private var resetWindowSizeItem: NSMenuItem!
    private var removePinItem: NSMenuItem!
    private var languageItem: NSMenuItem!
    private var debugLogsItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    private var axObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var observedPid: pid_t?

    private var isLaunching = false
    private var originalStatusTitle: String?
    private var originalStatusImage: NSImage?
    private var launchingTimer: Timer?
    private var launchingDotCount = 0

    init(profile: PinProfile, owner: AppDelegate) {
        self.profile = profile
        self.owner = owner
        setupStatusItem()
        refreshVisualState()
    }

    deinit {
        stopObserving()
        launchingTimer?.invalidate()
    }

    func destroy() {
        stopObserving()
        launchingTimer?.invalidate()
        if let button = statusItem.button {
            owner.unbindStatusButton(button)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func updateProfile(_ profile: PinProfile) {
        self.profile = profile
        refreshVisualState()
    }

    func refreshVisualState() {
        updateStatusItemAppearance()
        updateMenuStates()
    }

    func clearObservedIfBundleMatches(_ bundleId: String) {
        if profile.bundleId == bundleId {
            stopObserving()
        }
    }

    func handleStatusItemClick(event: NSEvent?) {
        guard let event else {
            return
        }
        if event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        toggleAppWindow()
    }

    func toggleAppWindow() {
        guard AXIsProcessTrusted() else {
            owner.ensureAccessibilityPermission()
            return
        }

        if isLaunching {
            return
        }

        let target = profile.targetApp
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId).first {
            if !running.isHidden {
                if appHasWindows(pid: running.processIdentifier) && isAppFrontmost(running) {
                    running.hide()
                    return
                }
            }
        }

        ensureRunningApp(target) { [weak self] runningApp in
            guard let self, let runningApp else {
                self?.owner.showAlert(title: "Launch Failed", message: "Could not launch the selected app.")
                return
            }

            if runningApp.isHidden {
                if let preWindow = self.findMainWindow(pid: runningApp.processIdentifier) {
                    let preFrame = self.desiredWindowFrame(for: target)
                    self.setWindowFrame(preWindow, frame: preFrame)
                }
                runningApp.unhide()
            }

            self.beginLaunchingUI()
            self.waitForMainWindow(app: runningApp) { window in
                guard let window else {
                    self.reopenWindowIfNeeded(target: target, runningApp: runningApp) { reopenedWindow in
                        self.endLaunchingUI(targetName: target.displayName)
                        guard let reopenedWindow else {
                            self.owner.showAlert(
                                title: "Window Not Found",
                                message: "The app has no visible window. Open a window in the app, then try again."
                            )
                            return
                        }
                        let frame = self.desiredWindowFrame(for: target)
                        self.setWindowFrame(reopenedWindow, frame: frame)
                        self.retryAlignWindowToStatusItem(reopenedWindow, target: target)
                        runningApp.activate(options: [.activateIgnoringOtherApps])
                        self.startObserving(window: reopenedWindow, pid: runningApp.processIdentifier, bundleId: target.bundleId)
                    }
                    return
                }

                self.endLaunchingUI(targetName: target.displayName)
                let frame = self.desiredWindowFrame(for: target)
                self.setWindowFrame(window, frame: frame)
                self.retryAlignWindowToStatusItem(window, target: target)
                runningApp.activate(options: [.activateIgnoringOtherApps])
                self.startObserving(window: window, pid: runningApp.processIdentifier, bundleId: target.bundleId)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = owner
            button.action = #selector(AppDelegate.statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            owner.bindStatusButton(button, profileID: profile.id)
        }

        statusMenu = NSMenu()
        toggleItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuToggle(_:)), keyEquivalent: "")
        manageItem = NSMenuItem(title: "", action: #selector(AppDelegate.openManagePins(_:)), keyEquivalent: "")
        useAppIconItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuToggleUseAppIcon(_:)), keyEquivalent: "")
        iconStyleItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuToggleIconStyle(_:)), keyEquivalent: "")
        hotKeyInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        setHotKeyItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuSetHotKey(_:)), keyEquivalent: "")
        clearHotKeyItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuClearHotKey(_:)), keyEquivalent: "")
        resetWindowSizeItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuResetWindowSize(_:)), keyEquivalent: "")
        removePinItem = NSMenuItem(title: "", action: #selector(AppDelegate.pinMenuRemovePin(_:)), keyEquivalent: "")
        languageItem = NSMenuItem(title: "", action: #selector(AppDelegate.toggleLanguage(_:)), keyEquivalent: "")
        debugLogsItem = NSMenuItem(title: "", action: #selector(AppDelegate.toggleDebugLogs(_:)), keyEquivalent: "")
        quitItem = NSMenuItem(title: "", action: #selector(AppDelegate.quitApp(_:)), keyEquivalent: "q")

        let items: [NSMenuItem] = [
            toggleItem,
            manageItem,
            NSMenuItem.separator(),
            useAppIconItem,
            iconStyleItem,
            NSMenuItem.separator(),
            hotKeyInfoItem,
            setHotKeyItem,
            clearHotKeyItem,
            resetWindowSizeItem,
            NSMenuItem.separator(),
            languageItem,
            debugLogsItem,
            NSMenuItem.separator(),
            removePinItem,
            quitItem
        ].compactMap { $0 }

        for item in items {
            statusMenu.addItem(item)
        }
        setProfileIDRepresentedObject()
    }

    private func setProfileIDRepresentedObject() {
        for item in [toggleItem, manageItem, useAppIconItem, iconStyleItem, setHotKeyItem, clearHotKeyItem, resetWindowSizeItem, removePinItem] {
            item?.representedObject = profile.id
            item?.target = owner
        }
    }

    private func updateMenuStates() {
        setProfileIDRepresentedObject()

        let hotKeyText = owner.hotKeyDisplayString(profile.hotKey)
        toggleItem.title = localizedString(en: "Toggle Bubble", zh: "切换气泡")
        manageItem.title = localizedString(en: "Manage Pins...", zh: "管理 Pins...")
        useAppIconItem.title = localizedString(en: "Use App Icon", zh: "使用应用图标")
        iconStyleItem.title = profile.useTemplateIcon
            ? localizedString(en: "App Icon Style: Gray", zh: "图标样式：灰色")
            : localizedString(en: "App Icon Style: Color", zh: "图标样式：彩色")
        hotKeyInfoItem.title = localizedString(
            en: "Hotkey: \(hotKeyText ?? "None")",
            zh: "快捷键：\(hotKeyText ?? "未设置")"
        )
        setHotKeyItem.title = localizedString(en: "Set Hotkey...", zh: "设置快捷键...")
        clearHotKeyItem.title = localizedString(en: "Clear Hotkey", zh: "清除快捷键")
        resetWindowSizeItem.title = localizedString(en: "Reset Window Size", zh: "重置窗口大小")
        languageItem.title = owner.uiLanguage == .english
            ? localizedString(en: "Language: English", zh: "语言：英文")
            : localizedString(en: "Language: Chinese", zh: "语言：中文")
        debugLogsItem.title = localizedString(en: "Debug Logs", zh: "调试日志")
        removePinItem.title = localizedString(en: "Remove This Pin", zh: "删除此 Pin")
        quitItem.title = localizedString(en: "Quit", zh: "退出")

        useAppIconItem.state = profile.useAppIcon ? .on : .off
        iconStyleItem.state = .on
        iconStyleItem.isEnabled = profile.useAppIcon
        hotKeyInfoItem.isEnabled = false
        clearHotKeyItem.isEnabled = profile.hotKey != nil
        debugLogsItem.state = owner.debugPlacement ? .on : .off
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else {
            return
        }

        if profile.useAppIcon {
            let icon = statusIcon(for: URL(fileURLWithPath: profile.appPath), useGray: profile.useTemplateIcon)
            button.image = icon
            button.title = ""
        } else {
            if let pin = pinIcon() {
                button.image = pin
                button.title = ""
            } else {
                button.image = nil
                button.title = profile.displayName
            }
        }
    }

    private func localizedString(en: String, zh: String) -> String {
        owner.localizedString(en: en, zh: zh)
    }

    private func statusIcon(for url: URL, useGray: Bool) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = false
        if useGray {
            return grayscaleImage(icon)
        }
        return icon
    }

    private func pinIcon() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "BarPin")
        let styled = image?.withSymbolConfiguration(config)
        styled?.isTemplate = true
        return styled
    }

    private func grayscaleImage(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else {
            return image
        }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(0.0, forKey: kCIInputSaturationKey)
        filter?.setValue(1.0, forKey: kCIInputContrastKey)
        guard let output = filter?.outputImage else {
            return image
        }
        let rep = NSCIImageRep(ciImage: output)
        let gray = NSImage(size: image.size)
        gray.addRepresentation(rep)
        return gray
    }

    private func ensureRunningApp(_ target: TargetApp, completion: @escaping (NSRunningApplication?) -> Void) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId).first {
            completion(running)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { app, _ in
            completion(app)
        }
    }

    private func waitForMainWindow(app: NSRunningApplication, completion: @escaping (AXUIElement?) -> Void) {
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var window: AXUIElement?
            for _ in 0..<60 {
                if let found = self.findMainWindow(pid: pid) {
                    window = found
                    break
                }
                usleep(50_000)
            }
            DispatchQueue.main.async {
                completion(window)
            }
        }
    }

    private func reopenWindowIfNeeded(target: TargetApp, runningApp: NSRunningApplication, completion: @escaping (AXUIElement?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { [weak self] app, _ in
            guard let self else {
                completion(nil)
                return
            }
            let appToUse = app ?? runningApp
            if appToUse.isHidden {
                if let preWindow = self.findMainWindow(pid: appToUse.processIdentifier) {
                    let preFrame = self.desiredWindowFrame(for: target)
                    self.setWindowFrame(preWindow, frame: preFrame)
                }
                appToUse.unhide()
            }
            self.waitForMainWindow(app: appToUse, completion: completion)
        }
    }

    private func findMainWindow(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        if let focusedWindow: AXUIElement = axCopyAttributeValue(appElement, attribute: kAXFocusedWindowAttribute as CFString),
           isUsableWindow(focusedWindow) {
            return focusedWindow
        }

        if let mainWindow: AXUIElement = axCopyAttributeValue(appElement, attribute: kAXMainWindowAttribute as CFString),
           isUsableWindow(mainWindow) {
            return mainWindow
        }

        if let windows: [AXUIElement] = axCopyAttributeValue(appElement, attribute: kAXWindowsAttribute as CFString) {
            if owner.debugPlacement {
                NSLog("Window list debug (\(windows.count)):")
                for (index, window) in windows.enumerated() {
                    let title = windowTitle(window) ?? "(no title)"
                    let role = windowRole(window) ?? "(no role)"
                    let subrole = windowSubrole(window) ?? "(no subrole)"
                    let minimized = windowIsMinimized(window) ?? false
                    let frame = windowFrame(window)
                    let frameText = frame.map { NSStringFromRect($0) } ?? "(nil)"
                    let settable = windowIsSettable(window)
                    NSLog("  [\(index)] title=\(title) role=\(role) subrole=\(subrole) minimized=\(minimized) settable=\(settable) frame=\(frameText)")
                }
            }

            let candidates = windows.filter { isUsableWindow($0) }
            if let best = candidates.max(by: { windowArea($0) < windowArea($1) }) {
                return best
            }
            return windows.first
        }
        return nil
    }

    private func appHasWindows(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        if let windows: [AXUIElement] = axCopyAttributeValue(appElement, attribute: kAXWindowsAttribute as CFString) {
            return !windows.isEmpty
        }
        return false
    }

    private func isAppFrontmost(_ app: NSRunningApplication) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return app.isActive
        }
        return frontmost.processIdentifier == app.processIdentifier
    }

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        if let minimized: Bool = axCopyAttributeValue(window, attribute: kAXMinimizedAttribute as CFString), minimized {
            return false
        }
        if let subrole: String = axCopyAttributeValue(window, attribute: kAXSubroleAttribute as CFString) {
            if subrole != (kAXStandardWindowSubrole as String)
                && subrole != (kAXDialogSubrole as String)
                && subrole != (kAXFloatingWindowSubrole as String) {
                return false
            }
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) != .success || !settable.boolValue {
            return false
        }
        if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) != .success || !settable.boolValue {
            return false
        }
        return true
    }

    private func windowTitle(_ window: AXUIElement) -> String? {
        axCopyAttributeValue(window, attribute: kAXTitleAttribute as CFString)
    }

    private func windowRole(_ window: AXUIElement) -> String? {
        axCopyAttributeValue(window, attribute: kAXRoleAttribute as CFString)
    }

    private func windowSubrole(_ window: AXUIElement) -> String? {
        axCopyAttributeValue(window, attribute: kAXSubroleAttribute as CFString)
    }

    private func windowIsMinimized(_ window: AXUIElement) -> Bool? {
        axCopyAttributeValue(window, attribute: kAXMinimizedAttribute as CFString)
    }

    private func windowIsSettable(_ window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) != .success || !settable.boolValue {
            return false
        }
        if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) != .success || !settable.boolValue {
            return false
        }
        return true
    }

    private func windowArea(_ window: AXUIElement) -> CGFloat {
        guard let frame = windowFrame(window) else {
            return 0
        }
        return max(0, frame.size.width) * max(0, frame.size.height)
    }

    private func desiredWindowFrame(for target: TargetApp) -> CGRect {
        let defaultSize = CGSize(width: 600, height: 400)
        let size = loadWindowSize(bundleId: target.bundleId) ?? defaultSize

        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else {
            if owner.debugPlacement {
                NSLog("Placement fallback: missing button/screen. Using menu-bar fallback frame.")
            }
            let fallback = fallbackMenuBarFrame(size: size)
            let targetScreen = screenContaining(point: CGPoint(x: fallback.midX, y: fallback.midY)) ?? NSScreen.main
            let axFallback = convertFrameToAX(fallback, screen: targetScreen)
            return axFallback
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
        let frame = frameBelowStatusItem(buttonFrame: buttonFrame, size: size, screen: screen)
        let axFrame = convertFrameToAX(frame, screen: screen)

        if owner.debugPlacement {
            NSLog("Placement debug:")
            NSLog("  buttonFrame: \(NSStringFromRect(buttonFrame))")
            NSLog("  screen.frame: \(NSStringFromRect(screen.frame))")
            NSLog("  screen.visibleFrame: \(NSStringFromRect(screen.visibleFrame))")
            NSLog("  target frame (appkit): \(NSStringFromRect(frame))")
            NSLog("  target frame (ax): \(NSStringFromRect(axFrame))")
        }
        return axFrame
    }

    private func fallbackMenuBarFrame(size: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = screenContaining(point: mouse) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let padding: CGFloat = 12
        var x = visible.maxX - size.width - padding
        var y = visible.maxY - size.height - 8
        if x < visible.minX { x = visible.minX }
        if y < visible.minY { y = visible.minY }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func screenContaining(point: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            return screen
        }
        return nil
    }

    private func centeredFrame(size: CGSize, screen: NSScreen?) -> CGRect {
        let fallback = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = screen?.visibleFrame ?? fallback
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        return CGRect(origin: origin, size: size)
    }

    private func frameBelowStatusItem(buttonFrame: CGRect, size: CGSize, screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let padding: CGFloat = 8
        var x = buttonFrame.midX - size.width / 2
        var y = visible.maxY - size.height - padding

        if x < visible.minX { x = visible.minX }
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if y < visible.minY { y = visible.minY }
        if y + size.height > visible.maxY { y = visible.maxY - size.height }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func convertFrameToAX(_ frame: CGRect, screen: NSScreen?) -> CGRect {
        guard let screen else {
            return frame
        }
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - frame.maxY
        return CGRect(x: frame.origin.x, y: axY, width: frame.width, height: frame.height)
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        var position = frame.origin
        var size = frame.size

        if let posValue = AXValueCreate(.cgPoint, &position) {
            let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            if error != .success {
                NSLog("AX set position failed: \(error.rawValue)")
            }
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            if error != .success {
                NSLog("AX set size failed: \(error.rawValue)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard let current = self.windowFrame(window) else { return }
            if self.owner.debugPlacement {
                NSLog("Placement verify:")
                NSLog("  expected frame: \(NSStringFromRect(frame))")
                NSLog("  actual frame: \(NSStringFromRect(current))")
            }
            if abs(current.origin.x - frame.origin.x) > 2 || abs(current.origin.y - frame.origin.y) > 2 {
                var retryPosition = frame.origin
                if let posValue = AXValueCreate(.cgPoint, &retryPosition) {
                    _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
                }
            }
        }
    }

    private func retryAlignWindowToStatusItem(_ window: AXUIElement, target: TargetApp) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let desired = self.desiredWindowFrame(for: target)
            self.setWindowFrame(window, frame: desired)
        }
    }

    private func startObserving(window: AXUIElement, pid: pid_t, bundleId: String) {
        if observedPid == pid, let observedWindow, CFEqual(observedWindow, window) {
            return
        }
        stopObserving()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else {
                return
            }
            let runtime = Unmanaged<PinRuntime>.fromOpaque(refcon).takeUnretainedValue()
            runtime.captureWindowFrame(from: element)
        }

        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let observer else {
            return
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObserver = observer
        observedWindow = window
        observedPid = pid

        if let size = windowSize(window) {
            saveWindowSize(size, bundleId: bundleId)
        }
    }

    private func stopObserving() {
        if let observer = axObserver, let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXResizedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
        observedWindow = nil
        observedPid = nil
    }

    private func captureWindowFrame(from element: AXUIElement) {
        if let size = windowSize(element) {
            saveWindowSize(size, bundleId: profile.bundleId)
        }
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = axCopyAttributeValue(window, attribute: kAXPositionAttribute as CFString),
              let sizeValue: AXValue = axCopyAttributeValue(window, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        guard let sizeValue: AXValue = axCopyAttributeValue(window, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        var size = CGSize.zero
        AXValueGetValue(sizeValue, .cgSize, &size)
        return size
    }

    private func saveWindowSize(_ size: CGSize, bundleId: String) {
        let dict: [String: Double] = ["w": Double(size.width), "h": Double(size.height)]
        UserDefaults.standard.set(dict, forKey: windowSizeKey(bundleId: bundleId))
    }

    private func loadWindowSize(bundleId: String) -> CGSize? {
        if let dict = UserDefaults.standard.dictionary(forKey: windowSizeKey(bundleId: bundleId)) as? [String: Double],
           let w = dict["w"],
           let h = dict["h"] {
            return CGSize(width: w, height: h)
        }
        if let dict = UserDefaults.standard.dictionary(forKey: windowFrameKey(bundleId: bundleId)) as? [String: Double],
           let w = dict["w"],
           let h = dict["h"] {
            return CGSize(width: w, height: h)
        }
        return nil
    }

    func resetWindowSize() {
        UserDefaults.standard.removeObject(forKey: windowSizeKey(bundleId: profile.bundleId))
        UserDefaults.standard.removeObject(forKey: windowFrameKey(bundleId: profile.bundleId))
    }

    private func windowFrameKey(bundleId: String) -> String {
        "windowFrame.\(bundleId)"
    }

    private func windowSizeKey(bundleId: String) -> String {
        "windowSize.\(bundleId)"
    }

    private func beginLaunchingUI() {
        guard !isLaunching else { return }
        isLaunching = true

        if let button = statusItem.button {
            originalStatusTitle = button.title
            originalStatusImage = button.image
        }

        launchingDotCount = 0
        launchingTimer?.invalidate()
        launchingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.launchingDotCount = (self.launchingDotCount % 3) + 1
            let dots = String(repeating: ".", count: self.launchingDotCount)
            if let button = self.statusItem.button {
                button.image = nil
                button.title = dots
            }
        }

        if let timer = launchingTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func endLaunchingUI(targetName: String) {
        guard isLaunching else { return }
        isLaunching = false
        launchingTimer?.invalidate()
        launchingTimer = nil
        if let button = statusItem.button {
            button.title = originalStatusTitle ?? targetName
            button.image = originalStatusImage
        }
    }

    private func axCopyAttributeValue<T>(_ element: AXUIElement, attribute: CFString) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        if error == .success {
            return value as? T
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var debugPlacement: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKeys.debugPlacement)
    }

    var uiLanguage: UILanguage {
        let raw = UserDefaults.standard.string(forKey: DefaultsKeys.uiLanguage)
        return UILanguage(rawValue: raw ?? "") ?? defaultLanguage()
    }

    private var profiles: [PinProfile] = []
    private var runtimes: [String: PinRuntime] = [:]
    private var statusButtonToProfile: [ObjectIdentifier: String] = [:]

    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyEventToProfileID: [UInt32: String] = [:]
    private let hotKeySignature = "BRPN".fourCharCode
    private var hotKeyCaptureDelegate: HotKeyCaptureWindowDelegate?

    private var manageWindow: NSWindow?
    private var managePopup: NSPopUpButton?
    private var manageInfoLabel: NSTextField?
    private var manageAddButton: NSButton?
    private var manageRemoveButton: NSButton?
    private var manageSetHotKeyButton: NSButton?
    private var manageClearHotKeyButton: NSButton?
    private var manageToggleIconButton: NSButton?
    private var manageToggleStyleButton: NSButton?
    private var reopenHandlerInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDefaults()
        migrateLegacyProfileIfNeeded()
        profiles = loadProfiles()
        ensureUniqueProfilesByBundleID()

        reconcileRuntimes()
        ensureAccessibilityPermission()
        observeAppTermination()
        installReopenEventHandlerIfNeeded()
        installHotKeyHandlerIfNeeded()
        _ = registerAllHotKeys(showError: false)

        if profiles.isEmpty {
            openManagePins(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openManagePins(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if profiles.isEmpty {
            openManagePins(nil)
        }
    }

    func bindStatusButton(_ button: NSStatusBarButton, profileID: String) {
        statusButtonToProfile[ObjectIdentifier(button)] = profileID
    }

    func unbindStatusButton(_ button: NSStatusBarButton) {
        statusButtonToProfile.removeValue(forKey: ObjectIdentifier(button))
    }

    func localizedString(en: String, zh: String) -> String {
        switch uiLanguage {
        case .english: return en
        case .chinese: return zh
        }
    }

    func hotKeyDisplayString(_ setting: HotKeySetting?) -> String? {
        guard let setting else {
            return nil
        }
        var parts: [String] = []
        if setting.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if setting.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if setting.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if setting.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyString(for: setting.keyCode))
        return parts.joined()
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func ensureAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            showAlert(
                title: localizedString(en: "Accessibility Permission Needed", zh: "需要辅助功能权限"),
                message: localizedString(
                    en: "Enable Accessibility access for BarPin in System Settings > Privacy & Security > Accessibility.",
                    zh: "请在 系统设置 > 隐私与安全性 > 辅助功能 中允许 BarPin。"
                )
            )
        }
    }

    @objc func statusItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else {
            return
        }
        guard let profileID = statusButtonToProfile[ObjectIdentifier(button)],
              let runtime = runtimes[profileID] else {
            return
        }
        runtime.handleStatusItemClick(event: NSApp.currentEvent)
    }

    @objc func pinMenuToggle(_ sender: Any?) {
        guard let profileID = profileID(from: sender),
              let runtime = runtimes[profileID] else {
            return
        }
        runtime.toggleAppWindow()
    }

    @objc func openManagePins(_ sender: Any?) {
        showManageWindow(preferredProfileID: profileID(from: sender))
    }

    @objc func pinMenuToggleUseAppIcon(_ sender: Any?) {
        guard let profileID = profileID(from: sender) else {
            return
        }
        updateProfile(profileID: profileID) { profile in
            profile.useAppIcon.toggle()
        }
    }

    @objc func pinMenuToggleIconStyle(_ sender: Any?) {
        guard let profileID = profileID(from: sender) else {
            return
        }
        updateProfile(profileID: profileID) { profile in
            profile.useTemplateIcon.toggle()
        }
    }

    @objc func pinMenuSetHotKey(_ sender: Any?) {
        let selectedID = profileID(from: sender) ?? selectedManageProfileID()
        guard let profileID = selectedID,
              let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }

        let currentSetting = profiles[index].hotKey
        guard let newSetting = captureHotKeySetting(current: currentSetting) else {
            return
        }
        if currentSetting == newSetting {
            return
        }

        if let conflict = profiles.first(where: { $0.id != profileID && $0.hotKey == newSetting }) {
            showAlert(
                title: localizedString(en: "Hotkey Conflict", zh: "快捷键冲突"),
                message: localizedString(
                    en: "This shortcut is already used by \(conflict.displayName).",
                    zh: "该快捷键已被 \(conflict.displayName) 使用。"
                )
            )
            return
        }

        let oldProfiles = profiles
        profiles[index].hotKey = newSetting
        persistProfiles()
        let failed = registerAllHotKeys(showError: false)
        if failed.contains(profileID) {
            profiles = oldProfiles
            persistProfiles()
            _ = registerAllHotKeys(showError: false)
            showAlert(
                title: localizedString(en: "Hotkey Unavailable", zh: "快捷键不可用"),
                message: localizedString(
                    en: "This shortcut is unavailable in the current system context.",
                    zh: "该快捷键在当前系统环境下不可用。"
                )
            )
            return
        }

        reconcileRuntimes()
        reloadManageWindow(preferredProfileID: profileID)
    }

    @objc func pinMenuClearHotKey(_ sender: Any?) {
        let selectedID = profileID(from: sender) ?? selectedManageProfileID()
        guard let profileID = selectedID,
              let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].hotKey = nil
        persistProfiles()
        _ = registerAllHotKeys(showError: false)
        reconcileRuntimes()
        reloadManageWindow(preferredProfileID: profileID)
    }

    @objc func pinMenuResetWindowSize(_ sender: Any?) {
        guard let profileID = profileID(from: sender),
              let runtime = runtimes[profileID] else {
            return
        }
        runtime.resetWindowSize()
    }

    @objc func pinMenuRemovePin(_ sender: Any?) {
        let selectedID = profileID(from: sender) ?? selectedManageProfileID()
        guard let profileID = selectedID,
              let profile = profiles.first(where: { $0.id == profileID }) else {
            return
        }

        let alert = NSAlert()
        alert.messageText = localizedString(en: "Remove Pin", zh: "删除 Pin")
        alert.informativeText = localizedString(
            en: "Remove \(profile.displayName) from BarPin?",
            zh: "要从 BarPin 删除 \(profile.displayName) 吗？"
        )
        alert.addButton(withTitle: localizedString(en: "Remove", zh: "删除"))
        alert.addButton(withTitle: localizedString(en: "Cancel", zh: "取消"))
        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
            return
        }

        profiles.removeAll { $0.id == profileID }
        persistProfiles()
        _ = registerAllHotKeys(showError: false)
        reconcileRuntimes()
        reloadManageWindow(preferredProfileID: profiles.first?.id)

        if profiles.isEmpty {
            openManagePins(nil)
        }
    }

    @objc func toggleLanguage(_ sender: Any?) {
        let newLanguage: UILanguage = (uiLanguage == .english) ? .chinese : .english
        UserDefaults.standard.set(newLanguage.rawValue, forKey: DefaultsKeys.uiLanguage)
        reconcileRuntimes()
        reloadManageWindow(preferredProfileID: selectedManageProfileID())
    }

    @objc func toggleDebugLogs(_ sender: Any?) {
        let current = UserDefaults.standard.bool(forKey: DefaultsKeys.debugPlacement)
        UserDefaults.standard.set(!current, forKey: DefaultsKeys.debugPlacement)
        reconcileRuntimes()
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            return
        }
        for runtime in runtimes.values {
            runtime.clearObservedIfBundleMatches(bundleId)
        }
    }

    @objc private func manageWindowSelectionChanged(_ sender: Any?) {
        reloadManageWindow(preferredProfileID: selectedManageProfileID())
    }

    @objc private func manageAddApp(_ sender: Any?) {
        showChooseAppPanel()
    }

    @objc private func manageRemoveSelected(_ sender: Any?) {
        pinMenuRemovePin(sender)
    }

    @objc private func manageSetHotKey(_ sender: Any?) {
        pinMenuSetHotKey(sender)
    }

    @objc private func manageClearHotKey(_ sender: Any?) {
        pinMenuClearHotKey(sender)
    }

    @objc private func manageToggleIcon(_ sender: Any?) {
        guard let profileID = selectedManageProfileID() else {
            return
        }
        updateProfile(profileID: profileID) { profile in
            profile.useAppIcon.toggle()
        }
        reloadManageWindow(preferredProfileID: profileID)
    }

    @objc private func manageToggleIconStyle(_ sender: Any?) {
        guard let profileID = selectedManageProfileID() else {
            return
        }
        updateProfile(profileID: profileID) { profile in
            profile.useTemplateIcon.toggle()
        }
        reloadManageWindow(preferredProfileID: profileID)
    }

    private func ensureDefaults() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKeys.debugPlacement) == nil {
            defaults.set(false, forKey: DefaultsKeys.debugPlacement)
        }
        if defaults.object(forKey: DefaultsKeys.uiLanguage) == nil {
            defaults.set(defaultLanguage().rawValue, forKey: DefaultsKeys.uiLanguage)
        }
    }

    private func migrateLegacyProfileIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: DefaultsKeys.pinProfiles) != nil {
            return
        }

        var migratedProfiles: [PinProfile] = []

        if let bundleId = defaults.string(forKey: DefaultsKeys.targetAppBundleId) {
            let path = defaults.string(forKey: DefaultsKeys.targetAppPath)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
            if let path {
                let name = defaults.string(forKey: DefaultsKeys.targetAppDisplayName) ?? bundleId
                let useAppIcon = defaults.object(forKey: DefaultsKeys.useAppIcon) as? Bool ?? true
                let useTemplateIcon = defaults.object(forKey: DefaultsKeys.useTemplateIcon) as? Bool ?? true

                var hotKey: HotKeySetting?
                if let keyCode = defaults.object(forKey: DefaultsKeys.hotKeyKeyCode) as? Int,
                   let modifiers = defaults.object(forKey: DefaultsKeys.hotKeyModifiers) as? Int {
                    hotKey = HotKeySetting(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
                }

                let profile = PinProfile(
                    id: UUID().uuidString,
                    appPath: path,
                    bundleId: bundleId,
                    displayName: name,
                    useAppIcon: useAppIcon,
                    useTemplateIcon: useTemplateIcon,
                    hotKey: hotKey
                )
                migratedProfiles.append(profile)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal"),
                  let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Calendar"
            let profile = PinProfile(
                id: UUID().uuidString,
                appPath: url.path,
                bundleId: bundleId,
                displayName: name,
                useAppIcon: true,
                useTemplateIcon: true,
                hotKey: nil
            )
            migratedProfiles.append(profile)
        }

        if let data = try? JSONEncoder().encode(migratedProfiles) {
            defaults.set(data, forKey: DefaultsKeys.pinProfiles)
        }
    }

    private func loadProfiles() -> [PinProfile] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.pinProfiles),
              let loaded = try? JSONDecoder().decode([PinProfile].self, from: data) else {
            return []
        }

        return loaded.compactMap { profile in
            let url = URL(fileURLWithPath: profile.appPath)
            guard let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier else {
                return nil
            }
            var normalized = profile
            normalized.bundleId = bundleId
            if normalized.displayName.isEmpty {
                normalized.displayName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleId
            }
            return normalized
        }
    }

    private func ensureUniqueProfilesByBundleID() {
        var seen: Set<String> = []
        var uniqueProfiles: [PinProfile] = []
        for profile in profiles {
            if seen.contains(profile.bundleId) {
                continue
            }
            seen.insert(profile.bundleId)
            uniqueProfiles.append(profile)
        }
        if uniqueProfiles != profiles {
            profiles = uniqueProfiles
            persistProfiles()
        }
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: DefaultsKeys.pinProfiles)
        }
    }

    private func reconcileRuntimes() {
        let desiredIDs = Set(profiles.map { $0.id })
        let existingIDs = Set(runtimes.keys)

        for removedID in existingIDs.subtracting(desiredIDs) {
            runtimes[removedID]?.destroy()
            runtimes.removeValue(forKey: removedID)
        }

        for profile in profiles {
            if let runtime = runtimes[profile.id] {
                runtime.updateProfile(profile)
            } else {
                runtimes[profile.id] = PinRuntime(profile: profile, owner: self)
            }
        }
    }

    private func updateProfile(profileID: String, mutate: (inout PinProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        mutate(&profiles[index])
        persistProfiles()
        reconcileRuntimes()
    }

    private func profileID(from sender: Any?) -> String? {
        if let item = sender as? NSMenuItem {
            return item.representedObject as? String
        }
        return selectedManageProfileID()
    }

    private func observeAppTermination() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared
        )
    }

    private func showChooseAppPanel() {
        let panel = NSOpenPanel()
        panel.level = .floating
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = localizedString(en: "Choose an App", zh: "选择应用")
        panel.message = localizedString(en: "Select an app to create a new pin.", zh: "选择要创建新 Pin 的应用。")

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.addProfile(from: url)
        }
    }

    private func addProfile(from url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else {
            showAlert(title: "Invalid App", message: "The selected app is missing a bundle identifier.")
            return
        }

        if profiles.contains(where: { $0.bundleId == bundleId }) {
            showAlert(
                title: localizedString(en: "App Already Added", zh: "应用已存在"),
                message: localizedString(
                    en: "This app already has a pin in BarPin.",
                    zh: "该应用已在 BarPin 中配置。"
                )
            )
            return
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleId
        let profile = PinProfile(
            id: UUID().uuidString,
            appPath: url.path,
            bundleId: bundleId,
            displayName: displayName,
            useAppIcon: true,
            useTemplateIcon: true,
            hotKey: nil
        )
        profiles.append(profile)
        persistProfiles()
        reconcileRuntimes()
        _ = registerAllHotKeys(showError: false)
        reloadManageWindow(preferredProfileID: profile.id)
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            AppDelegate.hotKeyEventHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandler
        )
        if status != noErr {
            NSLog("Install hotkey handler failed: \(status)")
        }
    }

    @discardableResult
    private func registerAllHotKeys(showError: Bool) -> Set<String> {
        unregisterAllHotKeys()

        var failedProfileIDs: Set<String> = []
        var eventID: UInt32 = 1

        for profile in profiles {
            guard let hotKey = profile.hotKey else {
                continue
            }

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: eventID)
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[eventID] = ref
                hotKeyEventToProfileID[eventID] = profile.id
            } else {
                failedProfileIDs.insert(profile.id)
                if showError {
                    showAlert(
                        title: localizedString(en: "Hotkey Unavailable", zh: "快捷键不可用"),
                        message: localizedString(
                            en: "Failed to register hotkey for \(profile.displayName). Please choose another one.",
                            zh: "无法为 \(profile.displayName) 注册快捷键，请更换组合。"
                        )
                    )
                }
            }
            eventID += 1
        }

        return failedProfileIDs
    }

    private func unregisterAllHotKeys() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyEventToProfileID.removeAll()
    }

    private func handleHotKeyEvent(_ eventID: EventHotKeyID) {
        guard eventID.signature == hotKeySignature else {
            return
        }

        guard let profileID = hotKeyEventToProfileID[eventID.id],
              let runtime = runtimes[profileID] else {
            return
        }

        DispatchQueue.main.async {
            runtime.toggleAppWindow()
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if status == noErr {
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            delegate.handleHotKeyEvent(hotKeyID)
        }
        return noErr
    }

    private func captureHotKeySetting(current: HotKeySetting?) -> HotKeySetting? {
        let currentText = hotKeyDisplayString(current) ?? localizedString(en: "None", zh: "未设置")
        let title = localizedString(en: "Press a new shortcut", zh: "按下新的快捷键")
        let hint = localizedString(en: "Current: \(currentText)", zh: "当前：\(currentText)")
        let help = localizedString(en: "Press Esc to cancel.", zh: "按 Esc 取消。")
        let invalidHint = localizedString(en: "Include ⌘ / ⌥ / ⌃", zh: "请包含 ⌘ / ⌥ / ⌃")

        var captured: HotKeySetting?
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = localizedString(en: "Set Hotkey", zh: "设置快捷键")
        panel.isReleasedWhenClosed = false
        panel.center()

        let delegate = HotKeyCaptureWindowDelegate { [weak self] in
            captured = nil
            panel.orderOut(nil)
            NSApp.stopModal()
            self?.hotKeyCaptureDelegate = nil
        }
        hotKeyCaptureDelegate = delegate
        panel.delegate = delegate

        let view = HotKeyCaptureView(
            frame: panel.contentView?.bounds ?? .zero,
            title: title,
            hint: hint,
            help: help,
            invalidHint: invalidHint,
            formatter: { [weak self] setting in
                self?.hotKeyDisplayString(setting) ?? ""
            },
            modifierMapper: { flags in
                var mods: UInt32 = 0
                if flags.contains(.command) { mods |= UInt32(cmdKey) }
                if flags.contains(.option) { mods |= UInt32(optionKey) }
                if flags.contains(.control) { mods |= UInt32(controlKey) }
                if flags.contains(.shift) { mods |= UInt32(shiftKey) }
                return mods
            },
            validator: { setting in
                let required = UInt32(cmdKey | optionKey | controlKey)
                return (setting.modifiers & required) != 0
            },
            onCapture: { [weak self] setting in
                captured = setting
                NSApp.stopModal()
                panel.orderOut(nil)
                self?.hotKeyCaptureDelegate = nil
            }
        )

        panel.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSApp.runModal(for: panel)

        return captured
    }

    private func keyString(for keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Tab): return "Tab"
        case UInt32(kVK_Escape): return "Esc"
        default: return "Key\(keyCode)"
        }
    }

    private func defaultLanguage() -> UILanguage {
        if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("zh") {
            return .chinese
        }
        return .english
    }

    private func showManageWindow(preferredProfileID: String?) {
        buildManageWindowIfNeeded()
        reloadManageWindow(preferredProfileID: preferredProfileID)
        guard let window = manageWindow else {
            return
        }

        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private func installReopenEventHandlerIfNeeded() {
        guard !reopenHandlerInstalled else {
            return
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        reopenHandlerInstalled = true
    }

    @objc private func handleReopenAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        showManageWindow(preferredProfileID: nil)
    }

    private func buildManageWindowIfNeeded() {
        if manageWindow != nil {
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedString(en: "Manage Pins", zh: "管理 Pins")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let popupLabel = NSTextField(labelWithString: localizedString(en: "Pin", zh: "Pin"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(manageWindowSelectionChanged(_:))

        let infoLabel = NSTextField(labelWithString: "")
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 3

        let addButton = NSButton(title: localizedString(en: "Add App...", zh: "添加应用..."), target: self, action: #selector(manageAddApp(_:)))
        let removeButton = NSButton(title: localizedString(en: "Remove Pin", zh: "删除 Pin"), target: self, action: #selector(manageRemoveSelected(_:)))
        let setHotKeyButton = NSButton(title: localizedString(en: "Set Hotkey...", zh: "设置快捷键..."), target: self, action: #selector(manageSetHotKey(_:)))
        let clearHotKeyButton = NSButton(title: localizedString(en: "Clear Hotkey", zh: "清除快捷键"), target: self, action: #selector(manageClearHotKey(_:)))
        let toggleIconButton = NSButton(title: localizedString(en: "Toggle Icon Source", zh: "切换图标来源"), target: self, action: #selector(manageToggleIcon(_:)))
        let toggleStyleButton = NSButton(title: localizedString(en: "Toggle Gray/Color", zh: "切换灰色/彩色"), target: self, action: #selector(manageToggleIconStyle(_:)))

        let row1 = NSStackView(views: [popupLabel, popup])
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 12

        let row2 = NSStackView(views: [addButton, removeButton])
        row2.orientation = .horizontal
        row2.distribution = .fillEqually
        row2.spacing = 12

        let row3 = NSStackView(views: [setHotKeyButton, clearHotKeyButton])
        row3.orientation = .horizontal
        row3.distribution = .fillEqually
        row3.spacing = 12

        let row4 = NSStackView(views: [toggleIconButton, toggleStyleButton])
        row4.orientation = .horizontal
        row4.distribution = .fillEqually
        row4.spacing = 12

        let stack = NSStackView(views: [row1, infoLabel, row2, row3, row4])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        manageWindow = window
        managePopup = popup
        manageInfoLabel = infoLabel
        manageAddButton = addButton
        manageRemoveButton = removeButton
        manageSetHotKeyButton = setHotKeyButton
        manageClearHotKeyButton = clearHotKeyButton
        manageToggleIconButton = toggleIconButton
        manageToggleStyleButton = toggleStyleButton
    }

    private func reloadManageWindow(preferredProfileID: String?) {
        guard let window = manageWindow,
              let popup = managePopup,
              let infoLabel = manageInfoLabel else {
            return
        }

        window.title = localizedString(en: "Manage Pins", zh: "管理 Pins")
        manageAddButton?.title = localizedString(en: "Add App...", zh: "添加应用...")
        manageRemoveButton?.title = localizedString(en: "Remove Pin", zh: "删除 Pin")
        manageSetHotKeyButton?.title = localizedString(en: "Set Hotkey...", zh: "设置快捷键...")
        manageClearHotKeyButton?.title = localizedString(en: "Clear Hotkey", zh: "清除快捷键")
        manageToggleIconButton?.title = localizedString(en: "Toggle Icon Source", zh: "切换图标来源")
        manageToggleStyleButton?.title = localizedString(en: "Toggle Gray/Color", zh: "切换灰色/彩色")

        let previousID = preferredProfileID ?? selectedManageProfileID()

        popup.removeAllItems()
        for profile in profiles {
            popup.addItem(withTitle: profile.displayName)
            popup.lastItem?.representedObject = profile.id
        }

        if let previousID,
           let index = profiles.firstIndex(where: { $0.id == previousID }) {
            popup.selectItem(at: index)
        } else if !profiles.isEmpty {
            popup.selectItem(at: 0)
        }

        guard let profileID = selectedManageProfileID(),
              let profile = profiles.first(where: { $0.id == profileID }) else {
            infoLabel.stringValue = localizedString(
                en: "No pin configured. Add an app to create your first BarPin bubble.",
                zh: "当前没有 Pin 配置。添加应用以创建第一个 BarPin 气泡。"
            )
            manageRemoveButton?.isEnabled = false
            manageSetHotKeyButton?.isEnabled = false
            manageClearHotKeyButton?.isEnabled = false
            manageToggleIconButton?.isEnabled = false
            manageToggleStyleButton?.isEnabled = false
            return
        }

        let hotKey = hotKeyDisplayString(profile.hotKey) ?? localizedString(en: "None", zh: "未设置")
        let iconSource = profile.useAppIcon
            ? localizedString(en: "App Icon", zh: "应用图标")
            : localizedString(en: "Pin Icon", zh: "图钉图标")
        let iconStyle = profile.useTemplateIcon
            ? localizedString(en: "Gray", zh: "灰色")
            : localizedString(en: "Color", zh: "彩色")

        infoLabel.stringValue = localizedString(
            en: "App: \(profile.displayName)\nHotkey: \(hotKey)\nIcon: \(iconSource) / \(iconStyle)",
            zh: "应用：\(profile.displayName)\n快捷键：\(hotKey)\n图标：\(iconSource) / \(iconStyle)"
        )

        manageRemoveButton?.isEnabled = true
        manageSetHotKeyButton?.isEnabled = true
        manageClearHotKeyButton?.isEnabled = profile.hotKey != nil
        manageToggleIconButton?.isEnabled = true
        manageToggleStyleButton?.isEnabled = profile.useAppIcon
    }

    private func selectedManageProfileID() -> String? {
        guard let popup = managePopup,
              let item = popup.selectedItem else {
            return nil
        }
        return item.representedObject as? String
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
