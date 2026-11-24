import Carbon
import Foundation
import XCTest
@testable import ClipNestCore

final class KeyRoutingTests: XCTestCase {
    private static let usKeys: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_F: "f",
        kVK_ANSI_I: "i", kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_Q: "q",
        kVK_ANSI_T: "t", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Z: "z", kVK_ANSI_2: "2", kVK_ANSI_Semicolon: ";", kVK_ANSI_Comma: ","
    ]

    private static func usLayout(_ code: Int) -> String? {
        usKeys[code]
    }

    func testOpenShortcutValidationAndCodableCompatibility() throws {
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_Space, layout: Self.usLayout), L("空格"))
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_Return, layout: Self.usLayout), L("回车"))
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_LeftArrow, layout: Self.usLayout), "←")
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_ForwardDelete, layout: Self.usLayout), "⌦")
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_F1, layout: Self.usLayout), "F1")
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_F20, layout: Self.usLayout), "F20")
        XCTAssertEqual(OpenShortcut.keyTitle(kVK_ANSI_A, layout: { _ in nil }), L("键码 %ld", kVK_ANSI_A))

        try KeyboardSettings().validate(layout: Self.usLayout)
        for code in [kVK_F1, kVK_F8, kVK_F20] {
            try KeyboardSettings(open: OpenShortcut(code: code, modifiers: 0)).validate(layout: Self.usLayout)
        }
        try KeyboardSettings(open: OpenShortcut(code: kVK_ANSI_Semicolon, modifiers: cmdKey | controlKey))
            .validate(layout: Self.usLayout)
        try KeyboardSettings(open: OpenShortcut(code: kVK_ANSI_T, modifiers: cmdKey)).validate(layout: Self.usLayout)

        let invalid: [(Int, Int)] = [
            (kVK_Space, 0), (kVK_ANSI_K, shiftKey), (kVK_Escape, cmdKey),
            (kVK_Control, cmdKey), (-1, optionKey), (kVK_ANSI_T, cmdKey | 0x10000),
            (kVK_ANSI_Q, cmdKey), (kVK_Delete, cmdKey), (kVK_Delete, cmdKey | optionKey),
            (kVK_ANSI_F, cmdKey), (kVK_ANSI_I, cmdKey), (kVK_ANSI_D, cmdKey),
            (kVK_ANSI_L, cmdKey), (kVK_ANSI_C, cmdKey), (kVK_ANSI_V, cmdKey),
            (kVK_ANSI_Z, cmdKey), (kVK_ANSI_2, controlKey)
        ]
        for (code, modifiers) in invalid {
            XCTAssertThrowsError(
                try KeyboardSettings(open: OpenShortcut(code: code, modifiers: modifiers), number: .control)
                    .validate(layout: Self.usLayout)
            )
        }
        for modifiers in [cmdKey, cmdKey | shiftKey] {
            XCTAssertThrowsError(
                try KeyboardSettings(open: OpenShortcut(code: kVK_Return, modifiers: modifiers), confirm: .commandEnter)
                    .validate(layout: Self.usLayout)
            )
        }

        // 验证已发布的 PropertyList 键名与枚举原始值保持兼容。
        let settings = KeyboardSettings(open: OpenShortcut(code: kVK_ANSI_K, modifiers: cmdKey | optionKey),
                                        confirm: .commandEnter, number: .control)
        let data = try PropertyListEncoder().encode(settings)
        let raw = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(raw["confirm"] as? String, "commandEnter")
        XCTAssertEqual(raw["number"] as? String, "control")
        let openDict = try XCTUnwrap(raw["open"] as? [String: Int])
        XCTAssertEqual(openDict["code"], kVK_ANSI_K)
        XCTAssertEqual(openDict["modifiers"], cmdKey | optionKey)
        XCTAssertEqual(try PropertyListDecoder().decode(KeyboardSettings.self, from: data), settings)
    }

    func testHistoryShortcutIndexAndLabels() {
        XCTAssertEqual(HistoryShortcut.fn.index(characters: "1", modifiers: .function), 0)
        XCTAssertEqual(HistoryShortcut.fn.index(characters: "9", modifiers: .function), 8)
        for modifiers: KeyModifiers in [[], .command, [.function, .command], [.function, .option], [.function, .shift], [.function, .control]] {
            XCTAssertNil(HistoryShortcut.fn.index(characters: "1", modifiers: modifiers))
        }
        for characters: String? in ["0", "10", "a", "\u{F704}", nil] {
            XCTAssertNil(HistoryShortcut.fn.index(characters: characters, modifiers: .function))
        }
        XCTAssertEqual(HistoryShortcut.fn.label(for: 0), "fn 1")
        XCTAssertEqual(HistoryShortcut.fn.label(for: 8), "fn 9")
        XCTAssertEqual(HistoryShortcut.fn.label(for: 9), "")
    }

    func testPanelKeyRouting() {
        let keyboard = KeyboardSettings()

        let numbered = PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_1, characters: "1", modifiers: .function),
                                              keyboard: keyboard, state: PanelKeyState())
        XCTAssertEqual(numbered, .numbered(0))
        XCTAssertTrue(numbered?.needsResults == true)

        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Space, characters: " ", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: true, hasEntries: true)),
            .togglePreview
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Space, characters: " ", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: false, previewOpen: false, hasEntries: true))
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Space, characters: " ", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: false, previewOpen: true, hasEntries: true)),
            .togglePreview
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Space, characters: " ", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(commands: true, searchEmpty: true, hasEntries: true))
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Space, characters: " ", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: true, previewOpen: false, hasEntries: false))
        )

        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Delete, characters: "\u{7f}", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: true)),
            .shortcut(.delete)
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Delete, characters: "\u{7f}", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState(searchEmpty: false))
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Delete, characters: "\u{7f}", modifiers: [.command, .shift]),
                                   keyboard: keyboard, state: PanelKeyState(commands: false, searchEmpty: false)),
            .shortcut(.delete)
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Delete, characters: "\u{7f}", modifiers: [.command, .shift]),
                                   keyboard: keyboard, state: PanelKeyState(commands: true))
        )

        let undo = PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_Z, characters: "z", modifiers: .command),
                                          keyboard: keyboard, state: PanelKeyState(canUndoDelete: true))
        XCTAssertEqual(undo, .undoDelete)
        XCTAssertFalse(undo?.needsResults == true)
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_Z, characters: "z", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState(canUndoDelete: false))
        )

        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_Comma, characters: ",", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState())
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_Q, characters: "q", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState())
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_F, characters: "f", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState()),
            .shortcut(.search)
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_I, characters: "i", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState()),
            .togglePreview
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_D, characters: "d", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState()),
            .shortcut(.favorite)
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_L, characters: "l", modifiers: .command),
                                   keyboard: keyboard, state: PanelKeyState()),
            .shortcut(.lists)
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Delete, characters: "\u{7f}", modifiers: [.command, .option]),
                                   keyboard: keyboard, state: PanelKeyState()),
            .shortcut(.clear)
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Escape, characters: "\u{1b}", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState()),
            .shortcut(.close)
        )

        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_DownArrow, characters: nil, modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState()),
            .step(1)
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_UpArrow, characters: nil, modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState()),
            .step(-1)
        )

        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState(commands: true, searching: false)),
            .runCommand
        )
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: .shift),
                                   keyboard: keyboard, state: PanelKeyState(commands: true, searching: false))
        )

        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: []),
                                   keyboard: keyboard, state: PanelKeyState()),
            .confirm
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: .shift),
                                   keyboard: keyboard, state: PanelKeyState()),
            .confirmText
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_ANSI_KeypadEnter, characters: "\r", modifiers: .function),
                                   keyboard: keyboard, state: PanelKeyState()),
            .confirm
        )

        let cmdEnter = KeyboardSettings(confirm: .commandEnter)
        XCTAssertNil(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: []),
                                   keyboard: cmdEnter, state: PanelKeyState())
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: .command),
                                   keyboard: cmdEnter, state: PanelKeyState()),
            .confirm
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Return, characters: "\r", modifiers: [.command, .shift]),
                                   keyboard: cmdEnter, state: PanelKeyState()),
            .confirmText
        )

        let tabConfirm = KeyboardSettings(confirm: .tab)
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Tab, characters: "\t", modifiers: []),
                                   keyboard: tabConfirm, state: PanelKeyState()),
            .confirm
        )
        XCTAssertEqual(
            PanelKeyRouting.action(for: KeyStroke(code: kVK_Tab, characters: "\t", modifiers: .shift),
                                   keyboard: tabConfirm, state: PanelKeyState()),
            .confirmText
        )
    }
}
