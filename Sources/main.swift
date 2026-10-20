import AppKit
import SwiftUI

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--list-taps") {
    do {
        let data = try JSONEncoder().encode(TapInventory.current())
        FileHandle.standardOutput.write(data + Data([10]))
        exit(0)
    } catch { exit(1) }
}

if let index = CommandLine.arguments.firstIndex(of: "--audio-worker") {
    let mode = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "live"
    AudioWorkerServer.run(mode: mode)
}

if let index = CommandLine.arguments.firstIndex(of: "--verify-worker"), CommandLine.arguments.count > index + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    DispatchQueue.global().async {
        WorkerVerification.run(reportURL: url)
        exit(0)
    }
    RunLoop.main.run()
    exit(0)
}

if CommandLine.arguments.contains("--list-audio") {
    let rows: [[String: Any]] = SourceDiscovery.scan().map { ["id": $0.id, "name": $0.name, "processes": $0.processes, "running": $0.running] }
    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var model: MixerModel!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.HaomingLyu613.VolumeMixer").first { $0.processIdentifier != getpid() && $0.activationPolicy != .prohibited }
        if let other {
            if let url = other.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                configuration.allowsRunningApplicationSubstitution = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            } else {
                other.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
            }
            return
        }
        let verifying = ["--verify-chrome", "--verify-output", "--verify-engine", "--verify-audio"].contains { CommandLine.arguments.contains($0) }
        model = MixerModel(automaticRefresh: !verifying)
        if verifying { model.cancelExternalWork = { NSApp.terminate(nil) } }
        if CommandLine.arguments.contains("--restore-default-volumes") { model.resetAll() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Volume Mixer"
        window.appearance = NSAppearance(named: .aqua)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 580, height: 680)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: MixerView(model: model).padding(.top, 24).preferredColorScheme(.light))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MainMixerWindow")
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Volume Mixer")
            button.toolTip = "Volume Mixer · Click to open, right-click for menu"
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        showWindow()
        if let index = CommandLine.arguments.firstIndex(of: "--verify-chrome"), CommandLine.arguments.count > index + 1 {
            model.starting = true
            model.outputName = "Verifying Chrome audio…"
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.global().asyncAfter(deadline: .now() + 110) {
                AudioTrace.event("deadline", "ChromeVerification")
                _exit(124)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                ChromeVerification.run(reportURL: url)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-output"), CommandLine.arguments.count > index + 1 {
            model.starting = true
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.global(qos: .userInitiated).async {
                OutputVerification.run(reportURL: url)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-engine"), CommandLine.arguments.count > index + 1 {
            model.starting = true
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.global(qos: .userInitiated).async {
                EngineVerification.run(reportURL: url)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-audio"), CommandLine.arguments.count > index + 1 {
            model.starting = true
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            DispatchQueue.global(qos: .userInitiated).async {
                AudioVerification.run(reportURL: url)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let width = min(window.frame.width, visible.width)
            let height = min(window.frame.height, visible.height)
            window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open Volume Mixer", action: #selector(showWindow), keyEquivalent: ""); open.target = self
            let toggle = menu.addItem(withTitle: model.starting ? "Cancel audio verification" : (model.enabled ? "Pause and restore original playback" : "Enable per-app volume"), action: #selector(toggleAudio), keyEquivalent: ""); toggle.target = self; toggle.isEnabled = true
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Volume Mixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { showWindow() }
    }
    @objc func toggleAudio() { model.toggleEnabled() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
