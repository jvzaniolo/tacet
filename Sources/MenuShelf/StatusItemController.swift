import AppKit

/// MenuShelf's own status item: left-click reveals/hides the Hidden apps,
/// right-click (or control-click) opens the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let openSettings: () -> Void

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        statusItem.autosaveName = "MenuShelfChevron"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "MenuShelf — click to show/hide, right-click for menu"
        }
        updateIcon()
    }

    func updateIcon() {
        // Chevron points left (“more to reveal”) while hidden apps are hidden.
        let name = model.isRevealed ? "chevron.right" : "chevron.left"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MenuShelf")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu()
        } else {
            model.toggleRevealed()
            updateIcon()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        model.rescan()
        buildMenu(menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach so a later left-click goes back to the toggle action.
        statusItem.menu = nil
    }

    private func buildMenu(_ menu: NSMenu) {
        let toggle = NSMenuItem(
            title: model.isRevealed ? "Hide Hidden Apps" : "Show Hidden Apps",
            action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Hidden Apps", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let hidden = model.hiddenApps
        if !model.hasAccessibility {
            let item = NSMenuItem(title: "Accessibility access needed…", action: #selector(openAXSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else if hidden.isEmpty {
            let item = NSMenuItem(title: "None — mark apps Hidden in Settings", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for app in hidden {
                let icon = app.icon.map(Self.menuIcon)
                if app.items.isEmpty {
                    let item = NSMenuItem(title: "\(app.name) — not on the bar", action: nil, keyEquivalent: "")
                    item.image = icon
                    item.isEnabled = false
                    menu.addItem(item)
                } else if app.items.count == 1, let only = app.items.first {
                    menu.addItem(pressItem(title: app.name, item: only, icon: icon))
                } else {
                    let parent = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
                    parent.image = icon
                    let sub = NSMenu()
                    for item in app.items {
                        sub.addItem(pressItem(title: item.displayName, item: item, icon: nil))
                    }
                    parent.submenu = sub
                    menu.addItem(parent)
                }
            }
        }

        let pending = model.appsNeedingRelaunch.filter { $0.pid > 0 }
        if !pending.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Relaunch to Apply", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for app in pending {
                let item = NSMenuItem(title: "Relaunch \(app.name)", action: #selector(relaunchApp(_:)), keyEquivalent: "")
                item.target = self
                item.image = app.icon.map(Self.menuIcon)
                item.representedObject = app.key
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit MenuShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func pressItem(title: String, item: MenuBarItem, icon: NSImage?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(pressMenuBarItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.image = icon
        menuItem.representedObject = PressTarget(item: item)
        return menuItem
    }

    private static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    @objc private func pressMenuBarItem(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? PressTarget else { return }
        // Let our menu finish closing before the other app opens its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let error = AX.press(target.item.pressElement)
            Log.write("AXPress \(target.item.displayName) (pid \(target.item.pid)) → \(error.rawValue)")
        }
    }

    @objc private func relaunchApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let app = model.listedApps.first(where: { $0.key == key }) else { return }
        model.relaunch(app)
    }

    @objc private func toggleFromMenu() {
        model.toggleRevealed()
        updateIcon()
    }

    @objc private func settingsFromMenu() { openSettings() }

    @objc private func openAXSettings() { OnboardingController.openAccessibilitySettings() }
}

/// Boxes the AXUIElement for `NSMenuItem.representedObject`.
private final class PressTarget: NSObject {
    let item: MenuBarItem
    init(item: MenuBarItem) { self.item = item }
}
