import AppKit
import ApplicationServices
import Carbon

private enum DefaultsKeys {
    static let targetAppPath = "targetAppPath"
    static let targetAppBundleId = "targetAppBundleId"
    static let targetAppDisplayName = "targetAppDisplayName"
    static let useAppIcon = "useAppIcon"
    static let useTemplateIcon = "useTemplateIcon"
    static let debugPlacement = "debugPlacement"
    static let uiLanguage = "uiLanguage"
    static let hotKeyKeyCode = "hotKeyKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
}

private struct TargetApp {
    let url: URL
    let bundleId: String
    let displayName: String
}

private enum UILanguage: String {
    case english = "en"
    case chinese = "zh"
}

private struct HotKeySetting {
    let keyCode: UInt32
    let modifiers: UInt32
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugPlacement: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKeys.debugPlacement)
    }
    private var uiLanguage: UILanguage {
        let raw = UserDefaults.standard.string(forKey: DefaultsKeys.uiLanguage)
        return UILanguage(rawValue: raw ?? "") ?? defaultLanguage()
    }
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var chooseAppItem: NSMenuItem!
    private var useAppIconItem: NSMenuItem!
    private var iconStyleItem: NSMenuItem!
    private var languageItem: NSMenuItem!
    private var debugLogsItem: NSMenuItem!
    private var hotKeyInfoItem: NSMenuItem!
    private var setHotKeyItem: NSMenuItem!
    private var resetHotKeyItem: NSMenuItem!
    private var resetWindowSizeItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var axObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var observedPid: pid_t?
    private var isLaunching = false
    private var originalStatusTitle: String?
    private var originalStatusImage: NSImage?
    private var launchingTimer: Timer?
    private var launchingDotCount = 0
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: "BRPN".fourCharCode, id: 1)
    private var hotKeyCaptureDelegate: HotKeyCaptureWindowDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        ensureAccessibilityPermission()
        ensureDefaultTargetApp()
        observeAppTermination()
        registerHotKey()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
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

    @objc private func chooseApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.level = .floating
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = localizedString(en: "Choose an App", zh: "选择应用")
        panel.message = localizedString(en: "Select an app to control from the menu bar.", zh: "选择要由菜单栏控制的应用。")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.saveTargetApp(url: url)
        }
    }

    @objc private func resetWindowPosition(_ sender: Any?) {
        guard let target = resolveTargetApp() else {
            return
        }
        UserDefaults.standard.removeObject(forKey: windowSizeKey(bundleId: target.bundleId))
        UserDefaults.standard.removeObject(forKey: windowFrameKey(bundleId: target.bundleId))
    }

    @objc private func toggleUseAppIcon(_ sender: Any?) {
        let current = UserDefaults.standard.bool(forKey: DefaultsKeys.useAppIcon)
        UserDefaults.standard.set(!current, forKey: DefaultsKeys.useAppIcon)
        updateStatusItemAppearance()
        updateMenuStates()
    }

    @objc private func toggleTemplateIcon(_ sender: Any?) {
        let current = UserDefaults.standard.bool(forKey: DefaultsKeys.useTemplateIcon)
        UserDefaults.standard.set(!current, forKey: DefaultsKeys.useTemplateIcon)
        updateStatusItemAppearance()
        updateMenuStates()
    }

    @objc private func toggleDebugLogs(_ sender: Any?) {
        let current = UserDefaults.standard.bool(forKey: DefaultsKeys.debugPlacement)
        UserDefaults.standard.set(!current, forKey: DefaultsKeys.debugPlacement)
        updateMenuStates()
    }

    @objc private func toggleLanguage(_ sender: Any?) {
        let newLanguage: UILanguage = (uiLanguage == .english) ? .chinese : .english
        UserDefaults.standard.set(newLanguage.rawValue, forKey: DefaultsKeys.uiLanguage)
        updateMenuStates()
    }

    @objc private func setHotKey(_ sender: Any?) {
        guard let setting = captureHotKeySetting() else {
            return
        }
        saveHotKeySetting(setting)
        registerHotKey(showError: true)
        updateMenuStates()
    }

    @objc private func resetHotKey(_ sender: Any?) {
        let setting = defaultHotKeySetting()
        saveHotKeySetting(setting)
        registerHotKey()
        updateMenuStates()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "BarPin"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu = NSMenu()
        chooseAppItem = NSMenuItem(title: "", action: #selector(chooseApp), keyEquivalent: "")
        useAppIconItem = NSMenuItem(title: "", action: #selector(toggleUseAppIcon), keyEquivalent: "")
        iconStyleItem = NSMenuItem(title: "", action: #selector(toggleTemplateIcon), keyEquivalent: "")
        languageItem = NSMenuItem(title: "", action: #selector(toggleLanguage), keyEquivalent: "")
        debugLogsItem = NSMenuItem(title: "", action: #selector(toggleDebugLogs), keyEquivalent: "")
        hotKeyInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        setHotKeyItem = NSMenuItem(title: "", action: #selector(setHotKey), keyEquivalent: "")
        resetHotKeyItem = NSMenuItem(title: "", action: #selector(resetHotKey), keyEquivalent: "")
        resetWindowSizeItem = NSMenuItem(title: "", action: #selector(resetWindowPosition), keyEquivalent: "")
        quitItem = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")

        statusMenu.addItem(chooseAppItem)
        statusMenu.addItem(useAppIconItem)
        statusMenu.addItem(iconStyleItem)
        statusMenu.addItem(languageItem)
        statusMenu.addItem(debugLogsItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(hotKeyInfoItem)
        statusMenu.addItem(setHotKeyItem)
        statusMenu.addItem(resetHotKeyItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(resetWindowSizeItem)
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(quitItem)
        updateMenuStates()
    }

    private func ensureAccessibilityPermission() {
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

    private func ensureDefaultTargetApp() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKeys.useAppIcon) == nil {
            defaults.set(true, forKey: DefaultsKeys.useAppIcon)
        }
        if defaults.object(forKey: DefaultsKeys.useTemplateIcon) == nil {
            defaults.set(true, forKey: DefaultsKeys.useTemplateIcon)
        }
        if defaults.object(forKey: DefaultsKeys.debugPlacement) == nil {
            defaults.set(false, forKey: DefaultsKeys.debugPlacement)
        }
        if defaults.object(forKey: DefaultsKeys.uiLanguage) == nil {
            defaults.set(defaultLanguage().rawValue, forKey: DefaultsKeys.uiLanguage)
        }
        if defaults.object(forKey: DefaultsKeys.hotKeyKeyCode) == nil ||
            defaults.object(forKey: DefaultsKeys.hotKeyModifiers) == nil {
            let setting = defaultHotKeySetting()
            saveHotKeySetting(setting)
        }
        if defaults.string(forKey: DefaultsKeys.targetAppBundleId) != nil {
            updateStatusItemAppearance()
            updateMenuStates()
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal"),
           let bundle = Bundle(url: url) {
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Calendar"
            saveTargetApp(url: url, displayName: displayName)
        }
    }

    private func saveTargetApp(url: URL, displayName: String? = nil) {
        guard let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else {
            showAlert(title: "Invalid App", message: "The selected app is missing a bundle identifier.")
            return
        }
        let name = displayName ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleId
        let defaults = UserDefaults.standard
        defaults.set(url.path, forKey: DefaultsKeys.targetAppPath)
        defaults.set(bundleId, forKey: DefaultsKeys.targetAppBundleId)
        defaults.set(name, forKey: DefaultsKeys.targetAppDisplayName)
        updateStatusItemAppearance()
    }

    private func resolveTargetApp() -> TargetApp? {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: DefaultsKeys.targetAppPath) {
            let url = URL(fileURLWithPath: path)
            if let bundle = Bundle(url: url),
               let bundleId = bundle.bundleIdentifier {
                let name = defaults.string(forKey: DefaultsKeys.targetAppDisplayName)
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? bundleId
                return TargetApp(url: url, bundleId: bundleId, displayName: name)
            }
        }
        if let bundleId = defaults.string(forKey: DefaultsKeys.targetAppBundleId),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let name = defaults.string(forKey: DefaultsKeys.targetAppDisplayName) ?? bundleId
            return TargetApp(url: url, bundleId: bundleId, displayName: name)
        }
        return nil
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let defaults = UserDefaults.standard
        let useAppIcon = defaults.bool(forKey: DefaultsKeys.useAppIcon)
        let useGrayIcon = defaults.bool(forKey: DefaultsKeys.useTemplateIcon)

        if useAppIcon, let target = resolveTargetApp() {
            let icon = statusIcon(for: target.url, useGray: useGrayIcon)
            button.image = icon
            button.title = ""
        } else {
            if let pin = pinIcon() {
                button.image = pin
                button.title = ""
            } else if let target = resolveTargetApp() {
                button.image = nil
                button.title = target.displayName
            } else {
                button.image = nil
                button.title = "BarPin"
            }
        }
    }

    private func updateMenuStates() {
        let defaults = UserDefaults.standard
        let useAppIcon = defaults.bool(forKey: DefaultsKeys.useAppIcon)
        let useGrayIcon = defaults.bool(forKey: DefaultsKeys.useTemplateIcon)
        let debugEnabled = defaults.bool(forKey: DefaultsKeys.debugPlacement)
        let hotKeyText = hotKeyDisplayString(currentHotKeySetting())
        chooseAppItem.title = localizedString(en: "Choose App...", zh: "选择应用...")
        useAppIconItem.title = localizedString(en: "Use App Icon", zh: "使用应用图标")
        iconStyleItem.title = useGrayIcon
            ? localizedString(en: "App Icon Style: Gray", zh: "图标样式：灰色")
            : localizedString(en: "App Icon Style: Color", zh: "图标样式：彩色")
        languageItem.title = uiLanguage == .english
            ? localizedString(en: "Language: English", zh: "语言：英文")
            : localizedString(en: "Language: Chinese", zh: "语言：中文")
        debugLogsItem.title = localizedString(en: "Debug Logs", zh: "调试日志")
        hotKeyInfoItem.title = localizedString(en: "Hotkey: \(hotKeyText)", zh: "快捷键：\(hotKeyText)")
        setHotKeyItem.title = localizedString(en: "Set Hotkey...", zh: "设置快捷键...")
        resetHotKeyItem.title = localizedString(en: "Reset Hotkey", zh: "重置快捷键")
        resetWindowSizeItem.title = localizedString(en: "Reset Window Size", zh: "重置窗口大小")
        quitItem.title = localizedString(en: "Quit", zh: "退出")

        useAppIconItem.state = useAppIcon ? .on : .off
        iconStyleItem.state = .on
        iconStyleItem.isEnabled = useAppIcon
        debugLogsItem.state = debugEnabled ? .on : .off
        hotKeyInfoItem.isEnabled = false
    }

    private func localizedString(en: String, zh: String) -> String {
        switch uiLanguage {
        case .english:
            return en
        case .chinese:
            return zh
        }
    }

    private func defaultLanguage() -> UILanguage {
        if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("zh") {
            return .chinese
        }
        return .english
    }

    private func defaultHotKeySetting() -> HotKeySetting {
        HotKeySetting(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey))
    }

    private func currentHotKeySetting() -> HotKeySetting {
        let defaults = UserDefaults.standard
        if let keyCode = defaults.object(forKey: DefaultsKeys.hotKeyKeyCode) as? Int,
           let modifiers = defaults.object(forKey: DefaultsKeys.hotKeyModifiers) as? Int {
            return HotKeySetting(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        }
        return defaultHotKeySetting()
    }

    private func saveHotKeySetting(_ setting: HotKeySetting) {
        let defaults = UserDefaults.standard
        defaults.set(Int(setting.keyCode), forKey: DefaultsKeys.hotKeyKeyCode)
        defaults.set(Int(setting.modifiers), forKey: DefaultsKeys.hotKeyModifiers)
    }

    private func registerHotKey(showError: Bool = false) {
        unregisterHotKey()
        installHotKeyHandlerIfNeeded()
        let setting = currentHotKeySetting()
        var newHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(setting.keyCode, setting.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newHotKeyRef)
        if status == noErr {
            hotKeyRef = newHotKeyRef
        } else {
            NSLog("Register hotkey failed: \(status)")
            if showError {
                showAlert(
                    title: localizedString(en: "Hotkey Unavailable", zh: "快捷键不可用"),
                    message: localizedString(
                        en: "This shortcut is already in use. Please choose another one.",
                        zh: "该快捷键已被占用，请更换其他组合。"
                    )
                )
            }
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }
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

    private func handleHotKeyEvent(_ eventId: EventHotKeyID) {
        guard eventId.signature == hotKeyID.signature, eventId.id == hotKeyID.id else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.toggleAppWindow()
        }
    }

    private func hotKeyDisplayString(_ setting: HotKeySetting) -> String {
        var parts: [String] = []
        if setting.modifiers & UInt32(controlKey) != 0 {
            parts.append("⌃")
        }
        if setting.modifiers & UInt32(optionKey) != 0 {
            parts.append("⌥")
        }
        if setting.modifiers & UInt32(shiftKey) != 0 {
            parts.append("⇧")
        }
        if setting.modifiers & UInt32(cmdKey) != 0 {
            parts.append("⌘")
        }
        parts.append(keyString(for: setting.keyCode))
        return parts.joined()
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

    private func captureHotKeySetting() -> HotKeySetting? {
        let current = hotKeyDisplayString(currentHotKeySetting())
        let title = localizedString(en: "Press a new shortcut", zh: "按下新的快捷键")
        let hint = localizedString(en: "Current: \(current)", zh: "当前：\(current)")
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
        centerPanel(panel)

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

    private func centerPanel(_ panel: NSPanel) {
        let targetScreen = statusItem.button?.window?.screen ?? NSScreen.main
        let frame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = panel.frame.size
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
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

    private func toggleAppWindow() {
        guard AXIsProcessTrusted() else {
            ensureAccessibilityPermission()
            return
        }
        guard let target = resolveTargetApp() else {
            chooseApp(nil)
            return
        }

        if isLaunching {
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleId).first {
            if !running.isHidden {
                // If the app has no windows (e.g. user closed the last window), don't hide it.
                if appHasWindows(pid: running.processIdentifier) {
                    running.hide()
                    return
                }
            }
        }

        ensureRunningApp(target) { [weak self] runningApp in
            guard let self, let runningApp else {
                self?.showAlert(title: "Launch Failed", message: "Could not launch the selected app.")
                return
            }

            if runningApp.isHidden {
                // Best effort: position any existing window before it becomes visible to reduce "flash".
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
                            self.showAlert(
                                title: "Window Not Found",
                                message: "The app has no visible window. Open a window in the app, then click the menu bar button again."
                            )
                            return
                        }
                        let frame = self.desiredWindowFrame(for: target)
                        self.setWindowFrame(reopenedWindow, frame: frame)
                        runningApp.activate(options: [.activateIgnoringOtherApps])
                        self.startObserving(window: reopenedWindow, pid: runningApp.processIdentifier, bundleId: target.bundleId)
                    }
                    return
                }
                self.endLaunchingUI(targetName: target.displayName)
                let frame = self.desiredWindowFrame(for: target)
                self.setWindowFrame(window, frame: frame)
                runningApp.activate(options: [.activateIgnoringOtherApps])
                self.startObserving(window: window, pid: runningApp.processIdentifier, bundleId: target.bundleId)
            }
        }
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
            if debugPlacement {
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

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        if let minimized: Bool = axCopyAttributeValue(window, attribute: kAXMinimizedAttribute as CFString),
           minimized {
            return false
        }
        if let subrole: String = axCopyAttributeValue(window, attribute: kAXSubroleAttribute as CFString) {
            if subrole != (kAXStandardWindowSubrole as String) &&
                subrole != (kAXDialogSubrole as String) &&
                subrole != (kAXFloatingWindowSubrole as String) {
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
        guard let frame = windowFrame(window) else { return 0 }
        return max(0, frame.size.width) * max(0, frame.size.height)
    }

    private func desiredWindowFrame(for target: TargetApp) -> CGRect {
        let defaultSize = CGSize(width: 600, height: 400)
        let size = loadWindowSize(bundleId: target.bundleId) ?? defaultSize
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen else {
            if debugPlacement {
                NSLog("Placement fallback: missing button/screen. Using centered frame.")
            }
            let fallback = centeredFrame(size: size, screen: NSScreen.main)
            let axFallback = convertFrameToAX(fallback, screen: NSScreen.main)
            if debugPlacement {
                NSLog("  target frame (appkit): \(NSStringFromRect(fallback))")
                NSLog("  target frame (ax): \(NSStringFromRect(axFallback))")
            }
            return axFallback
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = buttonWindow.convertToScreen(buttonFrameInWindow)
        let frame = frameBelowStatusItem(buttonFrame: buttonFrame, size: size, screen: screen)
        let axFrame = convertFrameToAX(frame, screen: screen)
        if debugPlacement {
            let screenFrame = screen.frame
            let visible = screen.visibleFrame
            NSLog("Placement debug:")
            NSLog("  buttonFrame: \(NSStringFromRect(buttonFrame))")
            NSLog("  screen.frame: \(NSStringFromRect(screenFrame))")
            NSLog("  screen.visibleFrame: \(NSStringFromRect(visible))")
            NSLog("  target frame (appkit): \(NSStringFromRect(frame))")
            NSLog("  target frame (ax): \(NSStringFromRect(axFrame))")
        }
        return axFrame
    }

    private func centeredFrame(size: CGSize, screen: NSScreen?) -> CGRect {
        let fallback = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = screen?.visibleFrame ?? fallback
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }

    private func frameBelowStatusItem(buttonFrame: CGRect, size: CGSize, screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let padding: CGFloat = 8
        var x = buttonFrame.midX - size.width / 2
        // Use the top of the visible frame (just below the menu bar) to avoid coordinate issues.
        var y = visible.maxY - size.height - padding

        if x < visible.minX {
            x = visible.minX
        }
        if x + size.width > visible.maxX {
            x = visible.maxX - size.width
        }
        if y < visible.minY {
            y = visible.minY
        }
        if y + size.height > visible.maxY {
            y = visible.maxY - size.height
        }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func convertFrameToAX(_ frame: CGRect, screen: NSScreen?) -> CGRect {
        guard let screen else { return frame }
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

        // Re-apply once shortly after to override apps that reposition themselves on show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard let current = self.windowFrame(window) else { return }
            if self.debugPlacement {
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

    private func startObserving(window: AXUIElement, pid: pid_t, bundleId: String) {
        if observedPid == pid, let observedWindow, CFEqual(observedWindow, window) {
            return
        }
        stopObserving()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            delegate.captureWindowFrame(from: element)
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

    private func observeAppTermination() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared
        )
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else {
            return
        }
        if bundleId == UserDefaults.standard.string(forKey: DefaultsKeys.targetAppBundleId) {
            stopObserving()
        }
    }

    private func captureWindowFrame(from element: AXUIElement) {
        guard let bundleId = UserDefaults.standard.string(forKey: DefaultsKeys.targetAppBundleId) else {
            return
        }
        if let size = windowSize(element) {
            saveWindowSize(size, bundleId: bundleId)
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
        let dict: [String: Double] = [
            "w": Double(size.width),
            "h": Double(size.height)
        ]
        UserDefaults.standard.set(dict, forKey: windowSizeKey(bundleId: bundleId))
    }

    private func loadWindowSize(bundleId: String) -> CGSize? {
        if let dict = UserDefaults.standard.dictionary(forKey: windowSizeKey(bundleId: bundleId)) as? [String: Double],
           let w = dict["w"],
           let h = dict["h"] {
            return CGSize(width: w, height: h)
        }

        // Backward compatibility: read old frame data and keep only size.
        if let dict = UserDefaults.standard.dictionary(forKey: windowFrameKey(bundleId: bundleId)) as? [String: Double],
           let w = dict["w"],
           let h = dict["h"] {
            return CGSize(width: w, height: h)
        }

        return nil
    }

    private func windowFrameKey(bundleId: String) -> String {
        "windowFrame.\(bundleId)"
    }

    private func windowSizeKey(bundleId: String) -> String {
        "windowSize.\(bundleId)"
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            launchingDotCount = (launchingDotCount % 3) + 1
            let dots = String(repeating: ".", count: launchingDotCount)
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
