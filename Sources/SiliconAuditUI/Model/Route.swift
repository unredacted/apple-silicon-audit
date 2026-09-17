import Foundation

/// Every screen the app can navigate to, on every platform. Compact widths push routes onto a
/// `NavigationStack`; regular widths select them in the sidebar. Fact and topic detail always
/// travel with their own `Report`, so a report received from a watch never resolves against the
/// phone's facts.
public enum Route: Hashable, Sendable {
    case overview
    /// One category of facts (a `ReportModel.Section` id).
    case category(String)
    /// Every category, grouped, behind one tap on compact widths and the watch.
    case allReadings
    case documented
    case measurement
    case aboutData
    /// Changes the monitor recorded, and its settings (SPEC §6.5).
    case changes
    case monitor
    /// Apple TV only: export lives in the sidebar because there are no sheets.
    case export

    /// Launch argument `-initialSelection <route>` (SPEC §6 tvOS): a category id or one of the
    /// `__…__` names. Kept stable because `Scripts/run-simulator.sh` and the evidence docs use them.
    public init?(launchArgument s: String) {
        switch s {
        case "", "__summary__", "__overview__": self = .overview
        case "__documented__": self = .documented
        case "__about_data__": self = .aboutData
        case "__measurement__": self = .measurement
        case "__all__": self = .allReadings
        case "__changes__": self = .changes
        case "__monitor__": self = .monitor
        case "__export__": self = .export
        default: self = .category(s)
        }
    }
}
