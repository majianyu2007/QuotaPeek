import AppKit
import SwiftUI
import Combine
import UserNotifications

@main
enum QuotaPeekApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "QuotaPeek 额度")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: QuotaPanel(
            model: model, openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }
        ))
        model.onChange = { [weak self] in self?.updateStatus() }
        model.$preferences.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &cancellables)
        UNUserNotificationCenter.current().delegate = self
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        updateStatus()
        if !model.configured || CommandLine.arguments.contains("--settings") {
            showSettings()
        } else {
            model.refreshAll()
            if CommandLine.arguments.contains("--show") { showPopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func updateStatus() {
        guard let model else { return }
        statusItem.button?.title = model.menuTitle.isEmpty ? "" : " \(model.menuTitle)"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = model.menuTooltip
        statusItem.button?.setAccessibilityLabel("QuotaPeek，\(model.menuTooltip)")
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            let overview = menu.addItem(withTitle: "全部槽位", action: #selector(selectSlot(_:)), keyEquivalent: "")
            overview.target = self
            overview.state = model.preferences.selectedProfileID == nil ? .on : .off
            for profile in model.preferences.profiles {
                let item = menu.addItem(withTitle: profile.name, action: #selector(selectSlot(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = model.preferences.selectedProfileID == profile.id ? .on : .off
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "全部刷新", action: #selector(refreshAll), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 QuotaPeek", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func refreshAll() { model.refreshAll() }
    @objc private func selectSlot(_ sender: NSMenuItem) { model.selectProfile(sender.representedObject as? String) }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showSettings() {
        popover.performClose(nil)
        if let settingsWindow, settingsWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: SettingsView(model: model) { [weak self] in
            self?.settingsWindow?.close()
            self?.showPopover()
        })
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "QuotaPeek"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 650, height: 510))
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "QuotaPeek")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 QuotaPeek", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
