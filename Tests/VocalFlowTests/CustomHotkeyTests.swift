import AppKit
import XCTest
@testable import VocalFlow

final class CustomHotkeyTests: XCTestCase {

    func testFunctionKeyWorksOnItsOwn() throws {
        let hotkey = try CustomHotkey.fromKeyPress(keyCode: 96, flags: [.function], characters: nil).get()
        XCTAssertEqual(hotkey.displayName, "F5")
        XCTAssertEqual(hotkey.modifierFlags, [], "the .function flag macOS adds to F-keys is ignored")
        XCTAssertFalse(hotkey.isModifierOnly)
    }

    func testCombinationRecordsModifiersInStandardOrder() throws {
        let hotkey = try CustomHotkey.fromKeyPress(keyCode: 49, flags: [.option, .control], characters: " ").get()
        XCTAssertEqual(hotkey.displayName, "⌃⌥Space")
        XCTAssertEqual(hotkey.modifierFlags, [.control, .option])
    }

    func testPlainLetterIsRefusedSoTypingIsNotBlocked() {
        let result = CustomHotkey.fromKeyPress(keyCode: 0, flags: [], characters: "a")
        XCTAssertEqual(try? result.get(), nil)
        if case .failure(let error) = result { XCTAssertEqual(error, .needsModifier) }
    }

    func testLetterWithModifierIsAccepted() throws {
        let hotkey = try CustomHotkey.fromKeyPress(keyCode: 2, flags: [.command, .shift], characters: "d").get()
        XCTAssertEqual(hotkey.displayName, "⇧⌘D")
    }

    func testEscapeIsReserved() {
        if case .failure(let error) = CustomHotkey.fromKeyPress(keyCode: 53, flags: [.control], characters: nil) {
            XCTAssertEqual(error, .escapeReserved)
        } else {
            XCTFail("Esc must not be recordable")
        }
    }

    func testLoneModifierKeys() {
        XCTAssertEqual(CustomHotkey.fromModifierKey(60)?.displayName, "Right Shift (⇧)")
        XCTAssertEqual(CustomHotkey.fromModifierKey(62)?.isModifierOnly, true)
        XCTAssertNil(CustomHotkey.fromModifierKey(57), "Caps Lock latches, so it can't be hold-to-talk")
        XCTAssertNil(CustomHotkey.fromModifierKey(0))
    }

    func testRightControlOption() {
        XCTAssertEqual(HotkeyOption.rightControl.keyCode, 62)
        XCTAssertEqual(HotkeyOption.rightControl.modifierFlag, .control)
        XCTAssertEqual(HotkeyOption(rawValue: "right_control"), .rightControl)
    }

    func testPersistenceRoundTrip() throws {
        let suite = "vocalflow.hotkeytest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkey = try CustomHotkey.fromKeyPress(keyCode: 49, flags: [.control, .option], characters: " ").get()
        hotkey.save(to: defaults)
        XCTAssertEqual(CustomHotkey.load(from: defaults), hotkey)
    }
}
