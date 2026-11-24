import SwiftUI

/// One code base for Apple TV and iPhone. Every size in the screens is written for a 1920-point-wide TV
/// seen from the couch; on iPhone the same layouts are drawn smaller:
///   S(x)  lengths (heights, spacing, padding, corner radii): about 42%
///   W(x)  widths: the same, but never wider than a phone screen's content area
///   F(x)  font sizes: about 55% (text shrinks less than pictures, so it stays readable)
enum Device {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif
}

func S(_ x: CGFloat) -> CGFloat { Device.isTV ? x : (x * 0.42).rounded() }
func W(_ x: CGFloat) -> CGFloat { Device.isTV ? x : min((x * 0.42).rounded(), 320) }
func F(_ x: CGFloat) -> CGFloat { Device.isTV ? x : max(12, (x * 0.55 * TextSize.factor).rounded()) }

/// iPhone text follows the Text Size setting (Release 4): 1 at the default size (today's sizes), smaller and larger
/// with the setting, capped at the first accessibility size so rows and buttons keep their shape. The app redraws
/// when the setting changes (RootView keys on it).
enum TextSize {
    static let cap: CGFloat = 1.65  // Accessibility 1 (28 / 17 pt body)
    static var factor: CGFloat {
        #if os(iOS)
        let body: CGFloat = 17
        return min(cap, max(0.82, UIFontMetrics(forTextStyle: .body).scaledValue(for: body) / body))
        #else
        return 1
        #endif
    }
}

extension View {
    /// A focus section on Apple TV (so Up/Down from anywhere in a row lands in it); nothing on iPhone.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Makes a non-button area focusable on Apple TV (to scroll to it with the remote); nothing on iPhone.
    @ViewBuilder func tvFocusable() -> some View {
        #if os(tvOS)
        focusable()
        #else
        self
        #endif
    }

    /// The tvOS card button look (a lifting, lit tile); a plain button on iPhone.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// Side by side on Apple TV, stacked on iPhone (poster beside the details, a row and its buttons).
struct AdaptiveStack<Content: View>: View {
    var tvAlignment: VerticalAlignment = .center
    var phoneAlignment: HorizontalAlignment = .leading
    var spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if Device.isTV {
            HStack(alignment: tvAlignment, spacing: spacing) { content }
        } else {
            VStack(alignment: phoneAlignment, spacing: spacing) { content }
        }
    }
}
