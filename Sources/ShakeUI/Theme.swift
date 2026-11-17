import SwiftUI
import ShakeCore

public enum ShakeTheme {
    public static let onAccent = Color.white
    public static let ink = Color.primary
    public static let secondary = Color.secondary
    public static let locale = Locale(identifier: "zh-Hans-CN")
    public static let accent = Color(red: 46 / 255, green: 71 / 255, blue: 156 / 255) // #2E479C
    public static let paper = Color.white
    public static let card = Color(red: 244 / 255, green: 246 / 255, blue: 252 / 255) // #F4F6FC
    public static let mutedInk = Color(red: 82 / 255, green: 97 / 255, blue: 122 / 255) // #52617A
    public static let separator = Color(red: 220 / 255, green: 228 / 255, blue: 240 / 255) // #DCE4F0

    public static func dateTime(in zone: TimeZone = .current) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, timeZone: zone).year().month(.wide).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    }

    public static func clock(in zone: TimeZone = .current) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    }
}

public extension ShakeCore.Category {
    var color: Color {
        switch self {
        case .food: Color(red: 0.53, green: 0.34, blue: 0.13)
        case .weight: Color(red: 0.15, green: 0.41, blue: 0.43)
        case .mood: Color(red: 0.46, green: 0.35, blue: 0.57)
        case .knowledge: Color(red: 0.24, green: 0.37, blue: 0.60)
        case .sport, .daily: Color(red: 0.30, green: 0.42, blue: 0.22)
        }
    }
}

public struct RecordPhoto: View {
    let data: Data?
    var contentMode: ContentMode = .fill
    public init(data: Data?, contentMode: ContentMode = .fill) { self.data = data; self.contentMode = contentMode }
    public var body: some View {
        Group {
            #if os(iOS)
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else { placeholder }
            #else
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else { placeholder }
            #endif
        }
    }
    private var placeholder: some View {
        ZStack { ShakeTheme.paper; Image(systemName: "photo").foregroundStyle(ShakeTheme.secondary) }
    }
}

public struct ShakeCard: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.background(ShakeTheme.card).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ShakeTheme.separator))
    }
}
