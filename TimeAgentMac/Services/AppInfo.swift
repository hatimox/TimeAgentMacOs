import Foundation

/// App version metadata. Reads the packaged bundle's Info.plist
/// (`CFBundleShortVersionString`, set by scripts/package.sh); falls back to
/// "dev" when running unbundled via `swift run`.
enum AppInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// e.g. "TimeAgent v1.0.0" (or "TimeAgent (dev)" when unbundled).
    static var displayVersion: String {
        version == "dev" ? "TimeAgent (dev)" : "TimeAgent v\(version)"
    }
}
