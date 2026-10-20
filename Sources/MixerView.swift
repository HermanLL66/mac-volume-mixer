import SwiftUI
import AppKit

private let accent = Color(red: 0.10, green: 0.48, blue: 0.45)
private let canvas = Color(red: 0.96, green: 0.97, blue: 0.96)

struct MixerView: View {
    @ObservedObject var model: MixerModel
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    if let notice = model.notice {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Audio control is unavailable", systemImage: "exclamationmark.circle.fill").font(.system(size: 13, weight: .semibold))
                            Text(notice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Open permissions", action: model.openPermissions)
                                Button("Retry", action: model.toggleEnabled)
                            }.buttonStyle(.bordered)
                        }.foregroundStyle(Color(red: 0.55, green: 0.30, blue: 0.08))
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let outputError = model.errors["output"] {
                        Text(outputError).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("App volumes").font(.system(size: 17, weight: .semibold))
                            Text("\(model.activeCount) apps playing audio").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()

                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                        if !model.search.isEmpty {
                            Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))

                    if model.visibleSources.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: model.search.isEmpty ? "waveform" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.6))
                            Text(model.search.isEmpty ? "Play some audio to discover an app" : "No matching apps").font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(model.visibleSources, id: \.id) { source in
                                AppVolumeRow(source: source, model: model)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle")
                        Text("Controls local playback. Browser tabs share one app volume. In-app volume also affects the final level.")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 2)
                }.padding(24)
            }
            footer
        }
        .background(canvas)
        .tint(accent)
        .frame(minWidth: 580, idealWidth: 640, maxWidth: .infinity, minHeight: 580, idealHeight: 720, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white).frame(width: 46, height: 46)
                .background(accent, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Volume Mixer").font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Every app, at the right volume.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset all", action: model.resetAll).font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(accent)
                .disabled(model.starting).help("Restore every app to 100% and unmute")
        }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(accent.opacity(0.1)).frame(width: 36, height: 36)
                    Image(systemName: "hifispeaker.fill").foregroundStyle(accent).font(.system(size: 15))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.outputName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.enabled ? accent : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                        Text(model.starting ? "Connecting and verifying audio access…" : (model.enabled ? "Per-app volume enabled" : "Adjustment paused"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Button(action: model.toggleEnabled) {
                    HStack(spacing: 5) {
                        if model.starting { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14) }
                        else { Image(systemName: model.enabled ? "pause.fill" : "play.fill").font(.system(size: 10)) }
                        Text(model.starting ? "Cancel" : (model.enabled ? "Pause" : "Enable"))
                            .font(.system(size: 12, weight: .semibold))
                    }.padding(.horizontal, 13).padding(.vertical, 9)
                        .foregroundStyle(model.enabled ? accent : .white)
                        .background(model.enabled ? accent.opacity(0.09) : accent, in: Capsule())
                }.buttonStyle(.plain)
            }
            if !model.enabled {
                Divider().opacity(0.5)
                Text(model.starting ? "Allow audio access in the system dialog. Control starts after verification." : "First use requires system audio access and plays a very quiet verification tone. Volume settings are saved automatically.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.1), lineWidth: 1))
    }
    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label("Local processing · No audio saved", systemImage: "lock.shield").font(.system(size: 10))
                Text("Reopen from the menu bar after closing").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.foregroundStyle(.secondary)
            Spacer()
            Button("Quit", action: { NSApp.terminate(nil) }).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .help("Quit and restore original app playback")
        }.padding(.horizontal, 24).padding(.vertical, 13).background(.white.opacity(0.65))
    }
}

private struct AppVolumeRow: View {
    let source: AudioSource
    @ObservedObject var model: MixerModel
    private var setting: VolumeSetting { model.setting(for: source.id) }
    private var isControlled: Bool { model.controlled.contains(source.id) }
    private var subtitle: String {
        if model.errors[source.id] != nil { return "Connection incomplete · Adjustment paused" }
        if !model.enabled { return "Applied when enabled" }
        if source.processes.isEmpty || !source.running { return "Waiting for playback · Setting saved" }
        if setting.gain != 1 && !isControlled { return "Connecting · Original playback active" }
        if setting.muted || setting.volume == 0 { return "Muted" }
        return isControlled ? "Playing · Per-app control active" : "Playing · Original volume"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                appIcon.frame(width: 35, height: 35)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(model.errors[source.id] == nil ? Color.secondary : .orange)
                }
                Spacer()
                Text(setting.muted ? "Mute" : "\(Int(setting.volume.rounded()))%")
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(setting.muted ? Color.secondary : accent)
                    .accessibilityLabel("\(source.name) volume \(setting.muted ? 0 : Int(setting.volume)) percent")
            }
            HStack(spacing: 11) {
                Button { model.toggleMute(source) } label: {
                    Image(systemName: setting.muted || setting.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13)).foregroundStyle(setting.muted ? .white : accent)
                        .frame(width: 31, height: 28)
                        .background(setting.muted ? accent : accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(setting.muted ? "Unmute" : "Mute")
                    .accessibilityLabel("\(source.name) \(setting.muted ? "Unmute" : "Mute")")
                Slider(value: Binding(get: { setting.volume }, set: { model.setVolume($0, for: source) }), in: 0...100, step: 1)
                    .accessibilityLabel("\(source.name) volume")
                Text("100").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 21)
            }.disabled(model.starting)
            if let error = model.errors[source.id] {
                HStack(alignment: .top, spacing: 10) {
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { model.refresh(force: true, retry: true) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
                }
            }
            if isControlled {
                GeometryReader { geometry in
                    let peak = max(0, min(1, Double(model.levels[source.id] ?? 0) * Double(setting.gain)))
                    Capsule().fill(accent.opacity(0.06))
                    Capsule().fill(accent.opacity(0.5)).frame(width: geometry.size.width * peak)
                }.frame(height: 3).accessibilityHidden(true)
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.035), lineWidth: 1))
    }
    @ViewBuilder private var appIcon: some View {
        if let url = source.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().padding(4).foregroundStyle(accent.opacity(0.5))
        }
    }
}
