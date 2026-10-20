import AppKit
import SwiftUI

// Renders the shipping SwiftUI view with isolated sample data. This utility
// never starts the audio engine or reads the user's saved volume preferences.
// Its images are interface illustrations, not recordings of live audio control.
@main
struct RenderShowcase {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: RenderShowcase OUTPUT_DIRECTORY\n", stderr)
            exit(2)
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "io.github.HaomingLyu613.VolumeMixer.showcase.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let states: [(String, Double, Double, Bool)] = [
            ("01-original", 100, 100, false),
            ("02-independent", 35, 80, false),
            ("03-muted", 35, 80, true),
            ("04-restored", 100, 100, false)
        ]
        for (name, browser, music, muted) in states {
            let model = MixerModel(automaticRefresh: false, settingsStore: store)
            model.outputName = "Default output"
            model.enabled = true
            model.sources = [
                AudioSource(id: "showcase.browser", name: "Browser", bundleURL: nil, processes: [1], running: true),
                AudioSource(id: "showcase.music", name: "Music player", bundleURL: nil, processes: [2], running: true)
            ]
            model.settings = [
                "showcase.browser": VolumeSetting(volume: browser, muted: muted, name: "Browser"),
                "showcase.music": VolumeSetting(volume: music, muted: false, name: "Music player")
            ]
            model.controlled = []
            if browser < 100 || muted { model.controlled.insert("showcase.browser") }
            if music < 100 { model.controlled.insert("showcase.music") }
            model.levels = ["showcase.browser": 0.65, "showcase.music": 0.8]
            let root = VStack(spacing: 0) {
                MixerView(model: model)
                Text("INTERFACE PREVIEW · SAMPLE APPS AND VALUES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.10, green: 0.48, blue: 0.45))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color(red: 0.91, green: 0.95, blue: 0.93))
            }.preferredColorScheme(.light)
            let frame = NSRect(x: 0, y: 0, width: 640, height: 780)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .aqua)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            hosting.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw NSError(domain: "Showcase", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate view bitmap"])
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "Showcase", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode view PNG"])
            }
            try png.write(to: destination.appendingPathComponent(name + ".png"))
            window.contentView = nil
        }
        print("Rendered four interface previews with sample data; no live audio was used.")
    }
}
