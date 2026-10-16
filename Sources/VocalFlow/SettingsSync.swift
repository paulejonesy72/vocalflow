import Foundation
import os.log

private let syncLogger = Logger(subsystem: "com.vocalflow.app", category: "sync")

// MARK: - Where the shared file lives

/// Settings sync is a plain JSON file in a folder that a file-sync service (iCloud Drive,
/// Dropbox, …) keeps in step across Macs. No iCloud entitlement or developer signing is
/// needed, so it works for ad-hoc and self-built copies too.
enum SyncLocation: String, CaseIterable, Identifiable {
    case iCloudDrive = "icloud"
    case dropbox
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .dropbox:     return "Dropbox"
        case .custom:      return "Custom folder"
        }
    }

    /// The VocalFlow folder inside the chosen service, or nil if the service isn't set up here.
    func folderURL(customPath: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        switch self {
        case .iCloudDrive:
            let root = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            return fm.fileExists(atPath: root.path) ? root.appendingPathComponent("VocalFlow") : nil
        case .dropbox:
            return Self.dropboxRoot(home: home)?.appendingPathComponent("VocalFlow")
        case .custom:
            let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
    }

    /// Dropbox's own folder: ~/Library/CloudStorage/Dropbox (or "Dropbox-<Team>") on current
    /// clients, ~/Dropbox on older ones. Third-party mounts that merely contain "Dropbox" in
    /// their name (CloudMounter, Mountain Duck, …) are deliberately not matched.
    private static func dropboxRoot(home: URL) -> URL? {
        let fm = FileManager.default
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        let names = (try? fm.contentsOfDirectory(atPath: cloudStorage.path)) ?? []
        if names.contains("Dropbox") { return cloudStorage.appendingPathComponent("Dropbox") }
        if let team = names.sorted().first(where: { $0.hasPrefix("Dropbox-") || $0.hasPrefix("Dropbox (") }) {
            return cloudStorage.appendingPathComponent(team)
        }
        let legacy = home.appendingPathComponent("Dropbox")
        return fm.fileExists(atPath: legacy.path) ? legacy : nil
    }
}

// MARK: - The shared document

enum SyncValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case strings([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let a = try? c.decode([String].self) { self = .strings(a) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s):  try c.encode(s)
        case .bool(let b):    try c.encode(b)
        case .strings(let a): try c.encode(a)
        }
    }
}

struct SyncedSetting: Codable, Equatable {
    var value: SyncValue
    var modified: Date
}

/// One Focus Words line. Deletions are kept as tombstones so a word removed on one Mac
/// isn't resurrected by another Mac that still had it.
struct SyncedEntry: Codable, Equatable {
    var line: String
    var modified: Date
    var deleted: Bool
}

struct SyncDocument: Codable, Equatable {
    var format = 1
    var settings: [String: SyncedSetting] = [:]
    /// Keyed by the lowercased trigger (the part before " : ").
    var dictionary: [String: SyncedEntry] = [:]

    /// Per-key last-writer-wins. Ties go to the lexically larger value so every Mac
    /// converges on the same result regardless of merge order.
    static func merge(_ a: SyncDocument, _ b: SyncDocument) -> SyncDocument {
        var out = SyncDocument()
        for key in Set(a.settings.keys).union(b.settings.keys) {
            out.settings[key] = newer(a.settings[key], b.settings[key]) {
                String(describing: $0.value) > String(describing: $1.value)
            }
        }
        for key in Set(a.dictionary.keys).union(b.dictionary.keys) {
            out.dictionary[key] = newer(a.dictionary[key], b.dictionary[key]) {
                ($0.deleted ? 0 : 1, $0.line) > ($1.deleted ? 0 : 1, $1.line)
            }
        }
        return out
    }

    private static func newer<T>(_ x: T?, _ y: T?, tieBreak: (T, T) -> Bool) -> T?
    where T: Equatable, T: HasModified {
        guard let x else { return y }
        guard let y else { return x }
        if x.modified != y.modified { return x.modified > y.modified ? x : y }
        return tieBreak(x, y) ? x : y
    }
}

protocol HasModified { var modified: Date { get } }
extension SyncedSetting: HasModified {}
extension SyncedEntry: HasModified {}

// MARK: - Local snapshot <-> document

/// What gets synced. Per-Mac things are deliberately absent: the microphone, the dictation
/// hotkey (keyboards and habits differ between Macs) and the sync location itself.
enum SyncedKeys {
    static let strings = [
        "selected_language", "selected_model", "transcription_engine",
        "selected_llm_provider", "selected_groq_model", "selected_openrouter_model",
        "selected_code_mix", "selected_target_language", "feedback_sound_name", "custom_system_prompt",
    ]
    static let bools = [
        "correction_mode_enabled", "grammar_correction_enabled", "code_mix_enabled", "target_language_enabled",
    ]
    static let stringArrays = ["favorite_focus_words"]
    /// Only synced when the user opts in — VocalFlow stores these as plain text.
    static let secrets = ["deepgram_api_key", "groq_api_key", "openrouter_api_key"]
    static let focusWords = "focus_words"
}

struct LocalSnapshot: Equatable {
    var settings: [String: SyncValue] = [:]
    /// Lowercased trigger → full line, in the user's order.
    var dictionary: [(key: String, line: String)] = []

    static func == (a: LocalSnapshot, b: LocalSnapshot) -> Bool {
        a.settings == b.settings && a.dictionary.map(\.key) == b.dictionary.map(\.key)
            && a.dictionary.map(\.line) == b.dictionary.map(\.line)
    }

    static func read(from defaults: UserDefaults, includeSecrets: Bool) -> LocalSnapshot {
        var snap = LocalSnapshot()
        for key in SyncedKeys.strings + (includeSecrets ? SyncedKeys.secrets : []) {
            if let s = defaults.string(forKey: key) { snap.settings[key] = .string(s) }
        }
        for key in SyncedKeys.bools {
            if let b = defaults.object(forKey: key) as? Bool { snap.settings[key] = .bool(b) }
        }
        for key in SyncedKeys.stringArrays {
            if let a = defaults.stringArray(forKey: key) { snap.settings[key] = .strings(a.sorted()) }
        }
        snap.dictionary = dictionaryLines(defaults.string(forKey: SyncedKeys.focusWords))
        return snap
    }

    static func dictionaryLines(_ raw: String?) -> [(key: String, line: String)] {
        FocusWordsDictionary.parseEntries(raw).map { entry in
            (entry.key.lowercased(), entry.key == entry.value ? entry.key : "\(entry.key) : \(entry.value)")
        }
    }
}

// MARK: - Sync engine

/// Keeps this Mac's settings and the shared file in step.
///
/// Every pass: work out what changed locally since the last pass (by diffing against a
/// mirror of the last-synced state), stamp those changes with the current time, merge with
/// the shared file per setting and per dictionary entry, write the result back, and apply
/// anything newer from other Macs to this one.
final class SettingsSync: ObservableObject {
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var resolvedFolder: URL?

    /// Called on the main queue with the UserDefaults keys that changed because of another Mac.
    var onApplied: (([String]) -> Void)?

    static let fileName = "settings.json"

    private let defaults: UserDefaults
    private let mirrorURL: URL
    private let queue = DispatchQueue(label: "com.vocalflow.sync")
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?
    private var now: () -> Date

    // Local-only preferences (never synced).
    static let enabledKey = "sync_enabled"
    static let locationKey = "sync_location"
    static let customPathKey = "sync_custom_path"
    static let includeSecretsKey = "sync_include_keys"

    init(defaults: UserDefaults = .standard, mirrorURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.mirrorURL = mirrorURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocalFlow/sync-mirror.json")
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var location: SyncLocation { SyncLocation(rawValue: defaults.string(forKey: Self.locationKey) ?? "") ?? .iCloudDrive }
    var includeSecrets: Bool { defaults.bool(forKey: Self.includeSecretsKey) }
    var folder: URL? { location.folderURL(customPath: defaults.string(forKey: Self.customPathKey) ?? "") }

    /// Begin syncing (if enabled): an immediate pass, then on every local change and every 10 s.
    func start() {
        stop()
        DispatchQueue.main.async { self.resolvedFolder = self.folder }
        guard isEnabled else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in self?.scheduleSoon() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.syncNow() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    /// Forget the last-synced state so this Mac rejoins as new (shared file wins conflicts).
    /// Used when the location changes.
    func resetMirror() {
        queue.async { try? FileManager.default.removeItem(at: self.mirrorURL) }
    }

    private func scheduleSoon() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// One full pass. Runs on the sync queue; safe to call from tests synchronously.
    func syncNow() {
        guard isEnabled else { return }
        guard let folder else {
            report(error: "\(location.displayName) isn't set up on this Mac.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(Self.fileName)
            let (remote, foldedCopies) = try readShared(file: file, folder: folder)
            let mirror = readMirror()
            let local = LocalSnapshot.read(from: defaults, includeSecrets: includeSecrets)

            let localDoc = Self.document(from: local, mirror: mirror, joining: mirror == nil && remote != nil, now: now())
            let merged = SyncDocument.merge(localDoc, remote ?? SyncDocument())

            if merged != remote || foldedCopies { try write(merged, to: file) }
            try cleanUpConflictCopies(in: folder)
            let changed = apply(merged, over: local)
            try saveMirror(merged)

            if !changed.isEmpty {
                syncLogger.info("Applied \(changed.count) setting(s) from another Mac")
                DispatchQueue.main.async { self.onApplied?(changed) }
            }
            DispatchQueue.main.async {
                self.lastSynced = Date()
                self.lastError = nil
                self.resolvedFolder = folder
            }
        } catch {
            report(error: error.localizedDescription)
        }
    }

    /// This Mac's state as a document: unchanged values keep the mirror's timestamp, changed
    /// ones get `now`. When joining an existing shared file for the first time, local values
    /// are stamped `.distantPast` so the shared file wins, while words only this Mac has are
    /// still added.
    static func document(from local: LocalSnapshot, mirror: SyncDocument?, joining: Bool, now: Date) -> SyncDocument {
        let stamp = joining ? Date.distantPast : now
        var doc = mirror ?? SyncDocument()
        for (key, value) in local.settings where doc.settings[key]?.value != value {
            doc.settings[key] = SyncedSetting(value: value, modified: stamp)
        }
        var seen = Set<String>()
        for (key, line) in local.dictionary {
            seen.insert(key)
            let existing = doc.dictionary[key]
            if existing == nil || existing!.deleted || existing!.line != line {
                doc.dictionary[key] = SyncedEntry(line: line, modified: stamp, deleted: false)
            }
        }
        for (key, entry) in doc.dictionary where !entry.deleted && !seen.contains(key) {
            doc.dictionary[key] = SyncedEntry(line: entry.line, modified: stamp, deleted: true)
        }
        return doc
    }

    /// Write merged values into UserDefaults; returns the keys that actually changed.
    private func apply(_ doc: SyncDocument, over local: LocalSnapshot) -> [String] {
        var changed: [String] = []
        let allowed = Set(SyncedKeys.strings + SyncedKeys.bools + SyncedKeys.stringArrays
                          + (includeSecrets ? SyncedKeys.secrets : []))
        for (key, setting) in doc.settings where allowed.contains(key) && local.settings[key] != setting.value {
            switch setting.value {
            case .string(let s):  defaults.set(s, forKey: key)
            case .bool(let b):    defaults.set(b, forKey: key)
            case .strings(let a): defaults.set(a, forKey: key)
            }
            changed.append(key)
        }

        // Keep this Mac's ordering for words it already has; append new ones oldest-first.
        let live = doc.dictionary.filter { !$0.value.deleted }
        var lines: [String] = local.dictionary.compactMap { live[$0.key]?.line }
        let known = Set(local.dictionary.map(\.key))
        lines += live.filter { !known.contains($0.key) }
            .sorted { $0.value.modified < $1.value.modified }
            .map(\.value.line)
        if lines != local.dictionary.map(\.line) {
            defaults.set(lines.joined(separator: "\n"), forKey: SyncedKeys.focusWords)
            changed.append(SyncedKeys.focusWords)
        }
        return changed
    }

    // MARK: File I/O

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Reads the shared file, folding in any conflict copies the sync service created.
    /// `foldedCopies` is true when copies were merged in, so the result must be written back
    /// before the copies are cleaned up.
    private func readShared(file: URL, folder: URL) throws -> (SyncDocument?, foldedCopies: Bool) {
        let fm = FileManager.default
        // iCloud Drive may have evicted the file to a placeholder; ask for it and catch up next pass.
        let placeholder = folder.appendingPathComponent(".\(Self.fileName).icloud")
        if !fm.fileExists(atPath: file.path), fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: file)
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Waiting for iCloud to download settings…"])
        }

        var docs: [SyncDocument] = []
        if let doc = try coordinatedRead(file) { docs.append(doc) }
        for url in conflictCopies(in: folder) {
            if let doc = try? coordinatedRead(url) { docs.append(doc) }
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? [] {
            if let doc = try? coordinatedRead(version.url) { docs.append(doc) }
        }
        guard var merged = docs.first else { return (nil, false) }
        for doc in docs.dropFirst() { merged = SyncDocument.merge(merged, doc) }
        return (merged, docs.count > 1)
    }

    private func coordinatedRead(_ url: URL) throws -> SyncDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try Self.decoder().decode(SyncDocument.self, from: result.get())
    }

    private func write(_ doc: SyncDocument, to url: URL) throws {
        let data = try Self.encoder().encode(doc)
        var writeError: Error?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
    }

    /// "settings (Paul's conflicted copy 2026-10-16).json", "settings 2.json", … — anything
    /// a sync service may create next to the real file.
    private func conflictCopies(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0 != Self.fileName && $0.hasPrefix("settings") && $0.hasSuffix(".json") }
            .map { folder.appendingPathComponent($0) }
    }

    private func cleanUpConflictCopies(in folder: URL) throws {
        let file = folder.appendingPathComponent(Self.fileName)
        for url in conflictCopies(in: folder) { try? FileManager.default.removeItem(at: url) }
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: file), !versions.isEmpty {
            versions.forEach { $0.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: file)
        }
    }

    private func readMirror() -> SyncDocument? {
        guard let data = try? Data(contentsOf: mirrorURL) else { return nil }
        return try? Self.decoder().decode(SyncDocument.self, from: data)
    }

    private func saveMirror(_ doc: SyncDocument) throws {
        try FileManager.default.createDirectory(at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(doc).write(to: mirrorURL, options: .atomic)
    }

    private func report(error message: String) {
        syncLogger.error("Sync failed: \(message, privacy: .public)")
        DispatchQueue.main.async { self.lastError = message }
    }
}
