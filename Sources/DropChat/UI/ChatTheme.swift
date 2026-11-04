import DroppyKit
import SwiftUI

/// Colors for the surface a chat is drawn on. The shelf is always dark; the
/// floating window follows the system appearance on Droppy's panel surface.
struct ChatTheme {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var raisedFill: Color
    var userBubble: Color

    static var shelf: ChatTheme {
        ChatTheme(
            primary: AdaptiveColors.notchSurfacePrimaryText,
            secondary: AdaptiveColors.notchSurfaceSecondaryText,
            tertiary: AdaptiveColors.notchSurfaceTertiaryText,
            raisedFill: AdaptiveColors.notchSurfaceCardFill,
            userBubble: AdaptiveColors.notchSurfaceCardHoverFill
        )
    }

    static var panel: ChatTheme {
        ChatTheme(
            primary: AdaptiveColors.primaryTextAuto,
            secondary: AdaptiveColors.secondaryTextAuto,
            tertiary: AdaptiveColors.secondaryTextAuto.opacity(0.75),
            raisedFill: AdaptiveColors.buttonBackgroundAuto,
            userBubble: AdaptiveColors.hoverBackgroundAuto
        )
    }
}

private struct ChatThemeKey: EnvironmentKey {
    static let defaultValue = ChatTheme.shelf
}

extension EnvironmentValues {
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}

/// Where a chat view is mounted.
enum ChatSurface {
    case shelf
    case floatingPanel
}
