import Foundation

package struct ClipboardColor: Equatable {
    package let red: CGFloat
    package let green: CGFloat
    package let blue: CGFloat
    package let alpha: CGFloat

    static func parse(_ content: Content) -> Self? {
        // 只识别独立色值，避免扫描长文或从一段代码里挑选颜色。
        guard case let .text(text) = content, text.utf8.prefix(1025).count <= 1024 else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return hex(value.dropFirst()) }
        return functional(value)
    }

    private static func hex(_ digits: Substring) -> Self? {
        let count = digits.utf8.count
        guard [3, 4, 6, 8].contains(count),
              digits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var full = count <= 4 ? digits.map { String(repeating: String($0), count: 2) }.joined() : String(digits)
        if full.count == 6 { full += "ff" }
        guard let value = UInt32(full, radix: 16) else { return nil }
        func channel(at shift: Int) -> CGFloat { CGFloat((value >> shift) & 255) / 255 }
        return Self(red: channel(at: 24), green: channel(at: 16), blue: channel(at: 8), alpha: channel(at: 0))
    }

    private static func functional(_ value: String) -> Self? {
        guard let open = value.firstIndex(of: "("), value.last == ")" else { return nil }
        let name = value[..<open]
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        let body = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let channels: [Substring]
        let alphaText: Substring
        if body.contains(",") {
            let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(trim)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            channels = Array(parts.prefix(3))
            alphaText = parts.count == 4 ? parts[3] : "1"
        } else {
            let parts = body.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return nil }
            channels = parts[0].split(whereSeparator: \.isWhitespace)
            alphaText = parts.count == 2 ? trim(parts[1]) : "1"
        }
        guard channels.count == 3, let alpha = fraction(alphaText, maximum: 1) else { return nil }
        if name.hasPrefix("rgb") {
            guard let red = fraction(channels[0], maximum: 255), let green = fraction(channels[1], maximum: 255),
                  let blue = fraction(channels[2], maximum: 255) else { return nil }
            return Self(red: red, green: green, blue: blue, alpha: alpha)
        }
        guard let hue = degrees(channels[0]), channels[1].hasSuffix("%"), channels[2].hasSuffix("%"),
              let saturation = fraction(channels[1], maximum: 100), let lightness = fraction(channels[2], maximum: 100)
        else { return nil }
        let amplitude = saturation * min(lightness, 1 - lightness)
        func component(_ offset: CGFloat) -> CGFloat {
            let k = (offset + hue / 30).truncatingRemainder(dividingBy: 12)
            return lightness - amplitude * max(-1, min(k - 3, 9 - k, 1))
        }
        return Self(red: component(0), green: component(8), blue: component(4), alpha: alpha)
    }

    private static func trim(_ value: Substring) -> Substring {
        Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func number(_ value: Substring) -> Double? {
        // Double 也接受十六进制浮点数，颜色分量只接受十进制。
        guard value.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 101].contains($0) }),
              let result = Double(value), result.isFinite else { return nil }
        return result
    }

    private static func fraction(_ value: Substring, maximum: Double) -> CGFloat? {
        let percent = value.hasSuffix("%")
        guard let amount = number(percent ? value.dropLast() : value) else { return nil }
        return CGFloat(max(0, min(1, amount / (percent ? 100 : maximum))))
    }

    private static func degrees(_ value: Substring) -> CGFloat? {
        for (suffix, turn) in [("turn", 1.0), ("grad", 400.0), ("rad", 2 * Double.pi), ("deg", 360.0), ("", 360.0)]
            where value.hasSuffix(suffix) {
            guard let amount = number(value.dropLast(suffix.count)) else { return nil }
            let angle = amount.truncatingRemainder(dividingBy: turn) / turn * 360
            return CGFloat(angle < 0 ? angle + 360 : angle)
        }
        return nil
    }
}
