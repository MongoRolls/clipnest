import Carbon

/// 读取当前 ASCII 兼容键盘布局。快捷键标签与直接粘贴共用同一套键位换算。
/// Carbon 以物理键位注册和投递按键，界面文字与 ⌘V 键码需要按当前布局换算。
enum KeyboardLayout {
    /// 物理键在当前布局下显示的字符；无法读取布局或该键不产生字符时返回 nil。
    static func characters(for code: Int) -> String? {
        guard let virtualKey = UInt16(exactly: code) else { return nil }
        return withLayout { translate(virtualKey, layout: $0, keyboardType: $1) }
    }

    /// 在当前布局中查找产生指定字符的物理键，兼容 Dvorak、Colemak 等非 QWERTY 布局。
    static func keyCode(for character: String) -> Int? {
        let target = character.lowercased()
        return withLayout { layout, keyboardType in
            (0..<128).first { translate(UInt16($0), layout: layout, keyboardType: keyboardType)?.lowercased() == target }
        }
    }

    private static func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>, UInt32) -> T?) -> T? {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // 布局数据归输入源所有，换算期间保持输入源存活。
        return withExtendedLifetime(source) { body(layout, UInt32(LMGetKbdType())) }
    }

    private static func translate(_ virtualKey: UInt16, layout: UnsafePointer<UCKeyboardLayout>, keyboardType: UInt32) -> String? {
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, virtualKey, UInt16(kUCKeyActionDisplay), 0, keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
