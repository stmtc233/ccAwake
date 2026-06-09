import Foundation

@objc public protocol CCAwakeHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void)
    func displaySleepNow(_ reply: @escaping (NSError?) -> Void)
}

public enum CCAwakeHelperConstants {
    public static let machServiceName = "com.stmtc.ccAwake.Helper"
    public static let plistName = "com.stmtc.ccAwake.Helper.plist"
    public static let bundleIdentifier = "com.stmtc.ccAwake.Helper"
}
