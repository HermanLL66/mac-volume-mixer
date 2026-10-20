import SwiftUI
import AppKit

private enum MixerPalette {
    static let paper = Color(red: 0.955, green: 0.953, blue: 0.929)
    static let ink = Color(red: 0.13, green: 0.16, blue: 0.15)
    static let secondary = Color(red: 0.46, green: 0.49, blue: 0.46)
    static let teal = Color(red: 0.18, green: 0.40, blue: 0.35)
    static let lime = Color(red: 0.83, green: 0.94, blue: 0.59)
    static let line = Color(red: 0.85, green: 0.87, blue: 0.83)
    static let track = Color(red: 0.89, green: 0.90, blue: 0.87)
    static let amber = Color(red: 0.65, green: 0.39, blue: 0.12)
}

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @State private var activeOnly = false
    private var displayedSources: [AudioSource] { model.visibleSources.filter { !activeOnly || $0.running } }
    // A worker failure can be mirrored in both fields. Present it once.
    private var globalIssue: String? { model.notice ?? model.errors["output"] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    outputCard
                    if let issue = globalIssue { issueCard(issue) }
                    applications
                    listeningNote
                }
                .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .background(MixerPalette.paper).foregroundStyle(MixerPalette.ink).tint(MixerPalette.teal)
        .frame(minWidth: 540, idealWidth: 600, maxWidth: .infinity,
               minHeight: 610, idealHeight: 770, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AUDIO / CONTROL").font(.system(size: 9, weight: .semibold)).tracking(2.3)
                    .foregroundStyle(MixerPalette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Volume Mixer").font(.system(size: 27, weight: .semibold))
                    Image(systemName: "waveform.path").font(.system(size: 20, weight: .light))
                        .foregroundStyle(MixerPalette.teal).accessibilityHidden(true)
                }
                Text("Every app, at the right volume.").font(.system(size: 12)).foregroundStyle(MixerPalette.secondary)
            }
            Spacer(minLength: 12)
            Button(action: model.resetAll) {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36).background(.white.opacity(0.7), in: Circle())
                        .overlay(Circle().strokeBorder(MixerPalette.line.opacity(0.7), lineWidth: 0.7))
                    Text("Reset all").font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(ConsoleButtonStyle()).keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model.starting).help("Restore every app to 100% and unmute (⌥⌘R)")
            .accessibilityLabel("Reset all apps to their original volume")
        }
        .padding(.horizontal, 29).padding(.top, 24).padding(.bottom, 26)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 13) {
                Image(systemName: "hifispeaker.2.fill").font(.system(size: 20, weight: .regular))
                    .foregroundStyle(MixerPalette.lime).frame(width: 44, height: 44)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("OUTPUT DEVICE").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.50))
                    Text(model.outputName).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: model.toggleEnabled) {
                    HStack(spacing: 7) {
                        if model.starting {
                            ProgressView().controlSize(.small).scaleEffect(0.72).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: model.enabled ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold))
                        }
                        Text(model.starting ? "Cancel" : (model.enabled ? "Pause" : "Enable"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 15).frame(height: 36).foregroundStyle(MixerPalette.ink)
                    .background(MixerPalette.lime, in: Capsule())
                }
                .buttonStyle(ConsoleButtonStyle())
                .help(model.starting ? "Cancel this audio connection" : (model.enabled ? "Pause adjustments and restore source audio" : "Enable independent app volumes"))
                .accessibilityLabel(model.starting ? "Cancel audio connection" : (model.enabled ? "Pause volume control" : "Enable volume control"))
            }
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            HStack(alignment: .center, spacing: 7) {
                Circle().fill(model.enabled ? MixerPalette.lime : .white.opacity(0.35)).frame(width: 5, height: 5)
                Text(model.starting ? "Connecting… Allow system audio access if prompted." : (model.enabled ? "Independent app volumes are active" : "Paused · Your settings are saved"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 4)
                if model.enabled {
                    Text("SYSTEM OUTPUT").font(.system(size: 8, weight: .medium)).tracking(1.2)
                        .foregroundStyle(.white.opacity(0.35)).accessibilityLabel("System output audio")
                }
            }
            if !model.enabled && !model.starting && globalIssue == nil {
                Text("First use requires system audio access and plays a very quiet verification tone.")
                    .font(.system(size: 10)).lineSpacing(3).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).background(MixerPalette.ink, in: RoundedRectangle(cornerRadius: 20))
    }

    private func issueCard(_ issue: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio needs attention").font(.system(size: 12, weight: .semibold))
                    Text(issue).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 16) {
                Button("Try again") {
                    if model.enabled { model.refresh(force: true, retry: true) }
                    else { model.toggleEnabled() }
                }.font(.system(size: 11, weight: .semibold)).disabled(model.starting)
                Button("Permissions", action: model.openPermissions).font(.system(size: 11))
            }.buttonStyle(.plain).padding(.leading, 22)
        }
        .foregroundStyle(MixerPalette.amber).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.92, blue: 0.81), in: RoundedRectangle(cornerRadius: 14))
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                Text("App volumes").font(.system(size: 18, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(MixerPalette.teal).frame(width: 4, height: 4)
                    Text("\(model.activeCount) playing").font(.system(size: 10, weight: .medium)).monospacedDigit()
                }.foregroundStyle(MixerPalette.secondary)
            }
            HStack(spacing: 0) {
                filterButton("All apps", active: !activeOnly) { activeOnly = false }
                filterButton("Playing", active: activeOnly) { activeOnly = true }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    TextField("Search apps", text: $model.search).font(.system(size: 11)).textFieldStyle(.plain)
                        .accessibilityLabel("Search apps")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .foregroundStyle(MixerPalette.secondary).frame(width: 116)
                .padding(.horizontal, 10).frame(height: 30)
                .background(.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 8))
            }
            if displayedSources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.search.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(MixerPalette.teal)
                    Text(model.search.isEmpty ? (activeOnly ? "No apps are playing yet" : "Play some audio to discover an app") : "No matching apps")
                        .font(.system(size: 12, weight: .medium))
                    Text(model.search.isEmpty ? "Saved levels apply the next time an app plays." : "Try another name, or clear your search.")
                        .font(.system(size: 11)).foregroundStyle(MixerPalette.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34)
                .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(displayedSources, id: \.id) { source in AppVolumeRow(source: source, model: model) }
                }
            }
        }
    }

    private func filterButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? MixerPalette.ink : MixerPalette.secondary)
                .padding(.horizontal, 11).frame(height: 30)
                .background(active ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? MixerPalette.line.opacity(0.65) : .clear, lineWidth: 0.7))
        }.buttonStyle(ConsoleButtonStyle()).accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var listeningNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 11))
            Text("100% is the original level. Boost up to 200%. Browser tabs share one app volume.")
                .font(.system(size: 10)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(MixerPalette.secondary).padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text("On-device. No recordings.").font(.system(size: 10))
            Spacer()
            Text("Reopen from the menu bar").font(.system(size: 9)).foregroundStyle(MixerPalette.secondary.opacity(0.75))
            Rectangle().fill(MixerPalette.line).frame(width: 1, height: 10).padding(.horizontal, 6)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10))
                .help("Quit and restore source audio")
        }
        .foregroundStyle(MixerPalette.secondary).padding(.horizontal, 29).frame(height: 43)
        .overlay(alignment: .top) { Rectangle().fill(MixerPalette.line.opacity(0.65)).frame(height: 0.7) }
    }
}

private struct AppVolumeRow: View {
    let source: AudioSource
    @ObservedObject var model: MixerModel
    private var setting: VolumeSetting { model.setting(for: source.id) }
    private var isControlled: Bool { model.controlled.contains(source.id) }
    private var isMuted: Bool { setting.muted || setting.volume == 0 }
    private var hasError: Bool { model.errors[source.id] != nil }
    private var color: Color { setting.volume > 100 && !isMuted ? MixerPalette.amber : MixerPalette.teal }
    private var subtitle: String {
        if hasError { return "Adjustment paused" }
        if !model.enabled { return "Saved · Applies when enabled" }
        if source.processes.isEmpty || !source.running { return "Ready when you play" }
        if setting.gain != 1 && !isControlled { return "Connecting · Original audio for now" }
        if isMuted { return "Muted" }
        return isControlled ? (setting.volume > 100 ? "Playing · Boost enabled" : "Playing · Independent volume") : "Playing · Original level"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                appIcon.frame(width: 35, height: 35).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if source.running && model.enabled && !hasError {
                            Circle().fill(isMuted ? MixerPalette.secondary.opacity(0.45) : color).frame(width: 4, height: 4)
                        }
                        Text(subtitle).font(.system(size: 10))
                            .foregroundStyle(hasError ? MixerPalette.amber : MixerPalette.secondary)
                    }
                }
                Spacer(minLength: 10)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(setting.muted ? "—" : "\(Int(setting.volume.rounded()))")
                        .font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                    if !setting.muted { Text("%").font(.system(size: 11, weight: .medium)) }
                }
                .foregroundStyle(isMuted ? MixerPalette.secondary : MixerPalette.ink)
                .accessibilityElement(children: .ignore).accessibilityLabel("\(source.name) volume")
                .accessibilityValue(setting.muted ? "Muted" : "\(Int(setting.volume.rounded())) percent")
            }
            HStack(alignment: .top, spacing: 12) {
                Button { model.toggleMute(source) } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isMuted ? MixerPalette.ink : MixerPalette.secondary)
                        .frame(width: 30, height: 28)
                        .background(isMuted ? MixerPalette.lime.opacity(0.65) : MixerPalette.paper.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(ConsoleButtonStyle()).help(setting.muted ? "Unmute" : "Mute")
                .accessibilityLabel("\(source.name): \(setting.muted ? "Unmute" : "Mute")").disabled(model.starting)
                VStack(spacing: 1) {
                    ConsoleVolumeSlider(volume: Binding(get: { setting.volume }, set: { model.setVolume($0, for: source) }),
                                        muted: isMuted, label: "\(source.name) volume")
                        .disabled(model.starting)
                    HStack {
                        Text("0")
                        Spacer(minLength: 0)
                        Text("200%")
                    }
                    .font(.system(size: 8, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MixerPalette.secondary.opacity(0.70)).frame(height: 10)
                    .overlay {
                        GeometryReader { geometry in
                            Text("100").font(.system(size: 8, weight: .medium)).monospacedDigit()
                                .foregroundStyle(MixerPalette.secondary.opacity(0.70))
                                .position(x: 8 + (geometry.size.width - 16) * VolumeScale.position(for: 100), y: 5)
                        }.accessibilityHidden(true)
                    }
                }
            }
            if let error = model.errors[source.id] {
                HStack(alignment: .top, spacing: 12) {
                    Text(error).font(.system(size: 10)).lineSpacing(3).foregroundStyle(MixerPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Retry") { model.refresh(force: true, retry: true) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MixerPalette.teal).disabled(model.starting)
                }
            }
            if isControlled {
                GeometryReader { geometry in
                    let peak = max(0, min(1, Double(model.levels[source.id] ?? 0)))
                    Capsule().fill(MixerPalette.track.opacity(0.45))
                    Capsule().fill(color.opacity(0.6)).frame(width: geometry.size.width * peak)
                }.frame(height: 2).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 16)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MixerPalette.line.opacity(0.5), lineWidth: 0.7))
    }

    @ViewBuilder private var appIcon: some View {
        if let url = source.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().padding(5).foregroundStyle(MixerPalette.teal.opacity(0.55))
        }
    }
}

// Geometry uses the perceptual scale; the percentage describes actual amplitude
// gain. Arrow keys and VoiceOver adjust one percentage point at a time.
private struct ConsoleVolumeSlider: View {
    @Binding var volume: Double
    let muted: Bool
    let label: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let usableWidth = max(1, geometry.size.width - 16)
            let position = min(1, max(0, VolumeScale.position(for: volume)))
            let unity = VolumeScale.position(for: 100)
            let accent = muted ? MixerPalette.secondary.opacity(0.45) : MixerPalette.teal
            ZStack(alignment: .leading) {
                Capsule().fill(MixerPalette.track).frame(height: 5).padding(.horizontal, 8)
                Capsule().fill(accent).frame(width: max(0, usableWidth * min(position, unity)), height: 5).offset(x: 8)
                if position > unity {
                    Rectangle().fill(muted ? accent : MixerPalette.amber)
                        .frame(width: usableWidth * (position - unity), height: 5).offset(x: 8 + usableWidth * unity)
                }
                Capsule().fill(MixerPalette.secondary.opacity(0.60))
                    .frame(width: 1, height: 11).offset(x: 8 + usableWidth * unity)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(muted ? MixerPalette.line : MixerPalette.teal.opacity(0.8), lineWidth: 1.4))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                    .frame(width: 16, height: 16).offset(x: usableWidth * position)
            }
            .frame(height: 28).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard isEnabled else { return }
                focused = true
                volume = VolumeScale.volume(for: min(1, max(0, (value.location.x - 8) / usableWidth)))
            })
        }
        .frame(height: 28).opacity(isEnabled ? 1 : 0.45)
        .focusable(isEnabled).focused($focused).focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? MixerPalette.teal.opacity(0.55) : .clear, lineWidth: 2).padding(-2))
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .onKeyPress(.downArrow) { adjust(-1); return .handled }
        .onKeyPress(.upArrow) { adjust(1); return .handled }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
        .accessibilityValue(muted ? "Muted, set to \(Int(volume.rounded())) percent" : "\(Int(volume.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
        .help("Use the arrow keys to fine-tune. 100% is the original level; 200% is the maximum.")
    }
    private func adjust(_ amount: Double) {
        guard isEnabled else { return }
        volume = min(200, max(0, volume.rounded() + amount))
    }
}

private struct ConsoleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(!isEnabled ? 0.40 : (configuration.isPressed ? 0.65 : 1))
    }
}
