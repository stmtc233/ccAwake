import Foundation
import ccAwakeCore

final class HelperTool: NSObject, NSXPCListenerDelegate, CCAwakeHelperProtocol {
    private let listener: NSXPCListener

    override init() {
        self.listener = NSXPCListener(machServiceName: CCAwakeHelperConstants.machServiceName)
        super.init()
        self.listener.delegate = self
    }

    func run() {
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CCAwakeHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping (NSError?) -> Void) {
        runPMSet(arguments: ["-a", "disablesleep", disabled ? "1" : "0"], reply: reply)
    }

    func displaySleepNow(_ reply: @escaping (NSError?) -> Void) {
        runPMSet(arguments: ["displaysleepnow"], reply: reply)
    }

    private func runPMSet(arguments: [String], reply: @escaping (NSError?) -> Void) {
        guard let result = ProcessRunner.run(executable: "/usr/bin/pmset", arguments: arguments) else {
            reply(NSError(
                domain: CCAwakeHelperConstants.bundleIdentifier,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not launch pmset."]
            ))
            return
        }

        guard result.status != 0 else {
            reply(nil)
            return
        }

        let message = result.stderrString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "pmset failed"

        reply(NSError(
            domain: CCAwakeHelperConstants.bundleIdentifier,
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

HelperTool().run()
