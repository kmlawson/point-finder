/// The version is `major.build`. The build number goes up by one with every
/// committed set of changes; the major number changes only when decided.
/// `scripts/build-app.sh` reads both numbers from this file.
public enum AppVersion {
    public static let major = 1
    public static let build = 4
    public static var string: String { "\(major).\(build)" }
}
