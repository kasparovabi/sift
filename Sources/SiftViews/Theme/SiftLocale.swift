import Foundation

/// The locale every date in the interface is formatted in.
///
/// Sift's interface is written in English, and `.relative(presentation: .named)` follows the
/// user's system locale, so on a machine set to another language the dates came out in that
/// language beside English labels ("3 dakika önce" under "TODAY"). Pinning the interface
/// locale keeps one language on screen. It deliberately does not touch `Calendar.current`,
/// so week boundaries and the first day of the week still follow the user's region.
public enum SiftLocale {
    public static let ui = Locale(identifier: "en_US")
}
