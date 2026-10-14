import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    let appState = AppState()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView().environmentObject(appState)
        let hostingController = NSHostingController(rootView: contentView)
        
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let img = NSImage(named: "MenuIcon") {
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "macAuViSy")
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            appState.refreshHardware()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
