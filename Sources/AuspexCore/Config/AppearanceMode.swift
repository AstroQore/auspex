import Foundation

/// Which appearance the window is drawn in.
///
/// ## Why "system" is the default
///
/// Auspex used to force dark at both roots. That was defensible while the
/// palette had one column — a light translation of a dark-only palette is a
/// worse dark palette — and it stopped being defensible the moment there were
/// two columns. A Mac app that ignores the appearance the person set for their
/// Mac is a Mac app that is wrong for half of every day: the board is
/// something people leave open beside their work, and at 3 pm on a bright desk
/// a near-black wall is the thing on screen everybody's eyes are working
/// hardest to read.
///
/// So the default is to follow, and the override exists for the two people who
/// want it anyway: the one who keeps the Mac in light and wants the wall dark
/// because the wall is a wall, and the one who keeps the Mac in dark and wants
/// this one window bright.
///
/// ## Why it is here and not in `@AppStorage`
///
/// The same reason the session window and the scene's annexes are in
/// `settings.json`: it changes what every surface *is*, and a person who set
/// it and found it back after a relaunch has been told their setting did not
/// take. It also has to be readable by anything that renders the app without a
/// window — the offscreen screenshot renderers take it as an argument — and a
/// preference nobody can find the file for is a preference nobody can undo by
/// hand.
public enum AppearanceMode: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Whatever the Mac is set to, and whatever it changes to at sunset.
    case system
    /// Always the light column, whatever the Mac says.
    case light
    /// Always the dark column, whatever the Mac says.
    case dark

    public var id: String { rawValue }

    /// What a fresh install gets, and what an unset key means.
    public static let standard = AppearanceMode.system

    /// What the picker's segment says.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// One line under the picker, saying what the choice actually does.
    public var detail: String {
        switch self {
        case .system:
            "Follows the appearance your Mac is set to, including a scheduled switch."
        case .light:
            "Always light, whatever your Mac is set to."
        case .dark:
            "Always dark, whatever your Mac is set to."
        }
    }
}
