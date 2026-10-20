import AppKit
import Combine

final class MixerModel: ObservableObject {
    @Published var sources: [AudioSource] = []
    @Published var settings: [String: VolumeSetting] = [:]
    @Published var outputName = "Detecting output device…"
    @Published var enabled = false
    @Published var starting = false
    @Published var notice: String?
    @Published var errors: [String: String] = [:]
    @Published var controlled: Set<String> = []
    @Published var levels: [String: Float] = [:]
    @Published var search = ""
    var cancelExternalWork: (() -> Void)?
    private let engine: AudioEngine
    private let settingsStore: UserDefaults
    private var refreshTimer: Timer?
    private var meterTimer: Timer?
    private let settingsKey = "appVolumeSettings.v1"
    private var refreshInFlight = false
    private var meterInFlight = false
    private var refreshPending = false
    private var retryPending = false
    private var refreshWork: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var gainWork: DispatchWorkItem?
    private var gainInFlight = false
    private var gainRevision = 0
    private var lastRefresh: TimeInterval = 0
    private var generation = 0
    private var closed = false

    init(engine: AudioEngine = AudioEngine(), automaticRefresh: Bool = true, settingsStore: UserDefaults = .standard) {
        self.engine = engine; self.settingsStore = settingsStore
        if let data = settingsStore.data(forKey: settingsKey), let saved = try? JSONDecoder().decode([String: VolumeSetting].self, from: data) { settings = saved }
        engine.failureHandler = { [weak self] message in
            guard let self, !self.closed else { return }
            self.cancelRefresh()
            self.enabled = false; self.starting = false
            self.controlled.removeAll(); self.levels.removeAll()
            self.notice = message
        }
        guard automaticRefresh else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.enabled, !self.starting, !self.meterInFlight, !self.refreshInFlight else { return }
            self.meterInFlight = true
            let token = self.generation
            self.engine.meters { [weak self] in
                guard let self, token == self.generation else { return }
                self.meterInFlight = false; self.levels = $0
            }
        }
    }
    var visibleSources: [AudioSource] { sources.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var activeCount: Int { sources.filter(\.running).count }
    func setting(for id: String) -> VolumeSetting { settings[id] ?? VolumeSetting() }
    func setVolume(_ value: Double, for source: AudioSource) {
        var setting = setting(for: source.id)
        setting.volume = min(200, max(0, value.isFinite ? value : 100)); setting.muted = false; setting.name = source.name
        settings[source.id] = setting
        persist(); scheduleGains()
        if enabled && !controlled.contains(source.id) { refresh(force: true) }
    }
    func toggleMute(_ source: AudioSource) {
        var setting = setting(for: source.id)
        setting.muted.toggle(); setting.name = source.name
        settings[source.id] = setting
        persist(); scheduleGains()
        if enabled && !controlled.contains(source.id) { refresh(force: true) }
    }
    func toggleEnabled() {
        guard !closed else { return }
        if starting, let cancelExternalWork { cancelExternalWork(); return }
        notice = nil
        cancelRefresh()
        let token = generation
        if enabled || starting {
            enabled = false; starting = false; controlled.removeAll(); levels.removeAll()
            engine.disable { [weak self] in
                guard let self, self.generation == token else { return }
                self.refresh(force: true)
            }
        } else {
            starting = true
            engine.enable { [weak self] result in
                guard let self, !self.closed, token == self.generation else { return }
                self.starting = false
                switch result {
                case .success: self.enabled = true; self.refresh(force: true, retry: true)
                case .failure(let error): self.notice = error.localizedDescription
                }
            }
        }
    }
    func resetAll() {
        for id in Array(settings.keys) { settings[id]?.volume = 100; settings[id]?.muted = false }
        notice = nil; persist(); refresh(force: true, retry: true)
    }
    func refresh(force: Bool = false, retry: Bool = false) {
        guard !closed else { return }
        if force || retry { refreshPending = true; retryPending = retryPending || retry }
        guard !starting, !refreshInFlight else { return }
        // A drag may produce hundreds of events per second. Admit one scan every
        // 200 ms at most, keeping only the latest settings and one pending retry.
        let delay = max(0, 0.2 - (ProcessInfo.processInfo.systemUptime - lastRefresh))
        if delay > 0 {
            guard refreshWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.refreshWork = nil; self?.refresh()
            }
            refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        refreshWork?.cancel(); refreshWork = nil
        let shouldRetry = retryPending
        refreshPending = false; retryPending = false
        lastRefresh = ProcessInfo.processInfo.systemUptime
        refreshInFlight = true
        let token = generation
        engine.refresh(settings: settings, retry: shouldRetry) { [weak self] snapshot in
            guard let self, !self.closed, token == self.generation else { return }
            self.sources = snapshot.sources; self.outputName = snapshot.outputName
            self.errors = snapshot.errors; self.controlled = snapshot.controlled
            self.refreshInFlight = false
            if self.refreshPending { self.refresh() }
        }
    }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func shutdown() {
        closed = true; cancelRefresh()
        refreshTimer?.invalidate(); meterTimer?.invalidate()
        persistWork?.cancel(); saveSettings()
        engine.shutdown()
    }
    private func cancelRefresh() {
        generation += 1
        refreshWork?.cancel(); refreshWork = nil
        refreshInFlight = false; meterInFlight = false
        refreshPending = false; retryPending = false
        gainWork?.cancel(); gainWork = nil; gainInFlight = false
    }
    private func scheduleGains() {
        gainRevision += 1
        guard enabled, !starting, !closed, gainWork == nil, !gainInFlight else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gainWork = nil
            guard self.enabled, !self.starting, !self.closed else { return }
            self.gainInFlight = true
            let token = self.generation, revision = self.gainRevision
            self.engine.updateGains(settings: self.settings) { [weak self] in
                guard let self, token == self.generation else { return }
                self.gainInFlight = false
                if self.gainRevision != revision { self.scheduleGains() }
            }
        }
        gainWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30, execute: work)
    }
    private func persist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSettings() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { settingsStore.set(data, forKey: settingsKey) }
    }
}
