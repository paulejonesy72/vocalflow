import XCTest
@testable import VocalFlow

final class SettingsSyncTests: XCTestCase {

    // MARK: - Merge rules

    func testNewerSettingWinsPerKey() {
        var a = SyncDocument(), b = SyncDocument()
        a.settings["selected_hotkey"] = SyncedSetting(value: .string("fn"), modified: t(2))
        b.settings["selected_hotkey"] = SyncedSetting(value: .string("right_option"), modified: t(1))
        b.settings["selected_language"] = SyncedSetting(value: .string("en-GB"), modified: t(1))

        let merged = SyncDocument.merge(a, b)
        XCTAssertEqual(merged.settings["selected_hotkey"]?.value, .string("fn"))
        XCTAssertEqual(merged.settings["selected_language"]?.value, .string("en-GB"))
    }

    func testMergeIsOrderIndependentOnTies() {
        var a = SyncDocument(), b = SyncDocument()
        a.settings["k"] = SyncedSetting(value: .string("x"), modified: t(5))
        b.settings["k"] = SyncedSetting(value: .string("y"), modified: t(5))
        a.dictionary["w"] = SyncedEntry(line: "w", modified: t(5), deleted: true)
        b.dictionary["w"] = SyncedEntry(line: "w", modified: t(5), deleted: false)
        XCTAssertEqual(SyncDocument.merge(a, b), SyncDocument.merge(b, a))
    }

    func testNewerDeletionBeatsOlderEntry() {
        var a = SyncDocument(), b = SyncDocument()
        a.dictionary["coley"] = SyncedEntry(line: "Coley", modified: t(1), deleted: false)
        b.dictionary["coley"] = SyncedEntry(line: "Coley", modified: t(2), deleted: true)
        XCTAssertEqual(SyncDocument.merge(a, b).dictionary["coley"]?.deleted, true)
    }

    // MARK: - Two Macs sharing one folder

    func testSecondMacJoinsAndAdoptsSharedSettingsButKeepsItsOwnWords() {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")

        defaultsA.set("en-GB", forKey: "selected_language")
        defaultsA.set("Coley\nbtw : by the way", forKey: "focus_words")
        macA.syncNow()

        defaultsB.set("en-US", forKey: "selected_language")
        defaultsB.set("Paul", forKey: "focus_words")
        macB.syncNow()

        XCTAssertEqual(defaultsB.string(forKey: "selected_language"), "en-GB", "joining Mac adopts shared settings")
        XCTAssertEqual(words(defaultsB), ["btw : by the way", "coley", "paul"])

        macA.syncNow()
        XCTAssertEqual(words(defaultsA), ["btw : by the way", "coley", "paul"], "A picks up B's word")
        XCTAssertEqual(defaultsA.string(forKey: "selected_language"), "en-GB")
    }

    func testChangesAndDeletionsPropagateBothWays() {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")
        defaultsA.set("Coley\nWhitton", forKey: "focus_words")
        macA.syncNow(); macB.syncNow()
        XCTAssertEqual(words(defaultsB), ["coley", "whitton"])

        clock += 10
        defaultsA.set("Whitton", forKey: "focus_words")          // A deletes Coley
        defaultsB.set("en-GB", forKey: "selected_language")       // B changes language
        macA.syncNow(); macB.syncNow(); macA.syncNow()

        XCTAssertEqual(words(defaultsB), ["whitton"], "deletion reaches B")
        XCTAssertEqual(defaultsA.string(forKey: "selected_language"), "en-GB", "B's change reaches A")
    }

    func testWordsLearnedOnBothMacsBetweenSyncsAreBothKept() {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")
        defaultsA.set("Paul", forKey: "focus_words")
        macA.syncNow(); macB.syncNow()

        clock += 10
        defaultsA.set("Paul\nWhitton", forKey: "focus_words")
        clock += 1
        defaultsB.set("Paul\nCami", forKey: "focus_words")
        macA.syncNow(); macB.syncNow(); macA.syncNow()

        XCTAssertEqual(words(defaultsA), ["cami", "paul", "whitton"])
        XCTAssertEqual(words(defaultsB), ["cami", "paul", "whitton"])
    }

    func testConflictCopiesAreFoldedInAndRemoved() throws {
        let (macA, defaultsA) = makeMac("A")
        defaultsA.set("Paul", forKey: "focus_words")
        macA.syncNow()

        var copy = SyncDocument()
        copy.dictionary["coley"] = SyncedEntry(line: "Coley", modified: t(9_999_999_999), deleted: false)
        let copyURL = folder.appendingPathComponent("settings (Paul's conflicted copy 2026-10-16).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(copy).write(to: copyURL)

        macA.syncNow()
        XCTAssertEqual(words(defaultsA), ["coley", "paul"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        let shared = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(shared.contains("Coley"), "merged copy is written back before cleanup")
    }

    func testAPIKeysOnlySyncWhenOptedIn() throws {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")
        defaultsA.set("gsk_secret", forKey: "groq_api_key")
        macA.syncNow(); macB.syncNow()
        XCTAssertNil(defaultsB.string(forKey: "groq_api_key"))
        let shared = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(shared.contains("gsk_secret"))

        defaultsA.set(true, forKey: SettingsSync.includeSecretsKey)
        defaultsB.set(true, forKey: SettingsSync.includeSecretsKey)
        clock += 10
        macA.syncNow(); macB.syncNow()
        XCTAssertEqual(defaultsB.string(forKey: "groq_api_key"), "gsk_secret")
    }

    func testHotkeyStaysPerMac() {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")
        defaultsA.set("fn", forKey: "selected_hotkey")
        defaultsB.set("right_option", forKey: "selected_hotkey")
        macA.syncNow(); macB.syncNow()
        clock += 10
        defaultsA.set("left_option", forKey: "selected_hotkey")
        macA.syncNow(); macB.syncNow()
        XCTAssertEqual(defaultsB.string(forKey: "selected_hotkey"), "right_option")
        XCTAssertEqual(defaultsA.string(forKey: "selected_hotkey"), "left_option")
    }

    func testMicrophoneIsNotSynced() {
        let (macA, defaultsA) = makeMac("A")
        let (macB, defaultsB) = makeMac("B")
        defaultsA.set("BuiltInMicrophoneDevice", forKey: "selected_audio_device_uid")
        macA.syncNow(); macB.syncNow()
        XCTAssertNil(defaultsB.string(forKey: "selected_audio_device_uid"))
    }

    // MARK: - Harness

    private var folder: URL!
    private var suites: [String] = []
    private var clock: TimeInterval = 1_000_000

    override func setUp() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocalflow-sync-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
    }

    private func makeMac(_ name: String) -> (SettingsSync, UserDefaults) {
        let suite = "vocalflow.synctest.\(name).\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: SettingsSync.enabledKey)
        defaults.set(SyncLocation.custom.rawValue, forKey: SettingsSync.locationKey)
        defaults.set(folder.path, forKey: SettingsSync.customPathKey)
        let sync = SettingsSync(
            defaults: defaults,
            mirrorURL: folder.appendingPathComponent(".mirror-\(name).json"),
            now: { [unowned self] in Date(timeIntervalSince1970: self.clock) }
        )
        return (sync, defaults)
    }

    private func words(_ defaults: UserDefaults) -> [String] {
        LocalSnapshot.dictionaryLines(defaults.string(forKey: "focus_words")).map { $0.line.lowercased() }.sorted()
    }

    private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
}
