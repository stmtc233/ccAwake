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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            reply(error as NSError)
            return
        }

        process.waitUntilExit()

        guard process.terminationStatus != 0 else {
            reply(nil)
            return
        }

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "pmset failed"

        reply(NSError(
            domain: CCAwakeHelperConstants.bundleIdentifier,
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

HelperTool().run()
