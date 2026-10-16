import Foundation
import os

public struct ProcessRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias ProcessRunner = (String, [String]) throws -> ProcessRunResult

public enum ClaudeKeychainCLI {
    private static let securityPath = "/usr/bin/security"
    private static let notFoundExitCode: Int32 = 44

    public static func readGenericPassword(service: String) -> KeychainReadResult {
        readGenericPassword(
            service: service,
            account: NSUserName(),
            processRunner: runProcess,
            secItemRead: ClaudeKeychain.readGenericPassword)
    }

    /// Uses Apple-signed `/usr/bin/security` as the silent primary path and
    /// picks among duplicate items like `ClaudeKeychain.select` (live
    /// 2026-10-14: a foreign JSON item listed before the CLI's): the current
    /// user's newest item — the CLI keys its writes on the username — else
    /// the newest item of any account.
    public static func readGenericPassword(
        service: String,
        account: String,
        processRunner: ProcessRunner,
        secItemRead: (String) -> KeychainReadResult
    ) -> KeychainReadResult {
        let keychains = searchList(processRunner: processRunner)
        do {
            let ownKeychain = try newestKeychain(
                service: service, account: account, in: keychains, processRunner: processRunner)
            let own = try processRunner(
                securityPath, secretQuery(service: service, account: account, keychain: ownKeychain))
            // Like `ClaudeKeychain.select`, an own item wins even when it holds
            // no credential: only a missing one opens other accounts' items.
            guard isNotFound(own) else {
                return mappedResult(own, fallback: secItemRead, service: service, account: account)
            }
            // Ranking every account means a whole-keychain dump: skip it when
            // the service has no item at all.
            let anyItem = try processRunner(securityPath, ["find-generic-password", "-s", service] + keychains)
            if isNotFound(anyItem) { return .notFound }
            let newest = try newestItem(service: service, in: keychains, processRunner: processRunner)
            let result = try processRunner(
                securityPath, secretQuery(service: service, account: newest?.account, keychain: newest?.keychain))
            return mappedResult(result, fallback: secItemRead, service: service, account: newest?.account)
        } catch {
            return secItemRead(service)
        }
    }

    private static func secretQuery(service: String, account: String?, keychain: String?) -> [String] {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")
        if let keychain { arguments.append(keychain) }
        return arguments
    }

    /// The keychains `security` searches when none is named. Empty when the
    /// list can't be read, which leaves the choice to `security`.
    private static func searchList(processRunner: ProcessRunner) -> [String] {
        guard let result = try? processRunner(securityPath, ["list-keychains"]),
              let text = String(data: result.stdout, encoding: .utf8) else { return [] }
        return text.matches(of: /"([^"\n]+)"/).map { String($0.1) }
    }

    /// A keychain rejects a second item with the same service and account, so
    /// same-account duplicates sit in different keychains, and `security`
    /// returns the one in the first keychain of the search list. Returns the
    /// keychain whose match changed last (attributes only, no secret read),
    /// or nil to leave the choice to `security`.
    private static func newestKeychain(
        service: String, account: String, in keychains: [String], processRunner: ProcessRunner
    ) throws -> String? {
        guard keychains.count > 1 else { return nil }
        let matches = try keychains.compactMap { keychain -> (keychain: String, modified: String)? in
            let result = try processRunner(securityPath, ["find-generic-password", "-s", service, "-a", account, keychain])
            guard result.exitCode == 0 else { return nil }
            return (keychain, modificationStamp(in: String(data: result.stdout, encoding: .utf8) ?? ""))
        }
        return matches.max { $0.modified < $1.modified }?.keychain
    }

    /// `security` finds only the first match in a keychain, so ranking every
    /// account's item reads `dump-keychain`: the attributes of every item in
    /// the keychains, no secret. Nil leaves the choice to `security`.
    private static func newestItem(
        service: String, in keychains: [String], processRunner: ProcessRunner
    ) throws -> DumpedItem? {
        let dump = try processRunner(securityPath, ["dump-keychain"] + keychains)
        let text = dump.exitCode == 0 ? String(data: dump.stdout, encoding: .utf8) ?? "" : ""
        let serviceLine = #""svce"<blob>="\#(service)""#
        let items = ("\n" + text).components(separatedBy: "\nkeychain: \"").dropFirst().compactMap {
            DumpedItem(record: $0, serviceLine: serviceLine)
        }
        guard let newest = items.max(by: { $0.modified < $1.modified }) else {
            Log.keychain.error("""
                keychain dump (exit \(dump.exitCode)) lists no item on \(service, privacy: .public); \
                reading the first match
                """)
            return nil
        }
        return newest
    }

    /// "mdat" is fixed-width UTC (YYYYMMDDhhmmssZ), so text order is time
    /// order; empty when absent.
    private static func modificationStamp(in attributes: String) -> String {
        attributes.firstMatch(of: /"mdat"<timedate>=\S+\s+"(\d{14})Z/).map { String($0.1) } ?? ""
    }

    /// One `dump-keychain` record, split after its leading `keychain: "`.
    private struct DumpedItem {
        let keychain: String
        let account: String?
        let modified: String

        /// Nil unless the record is an item on the service. The match takes
        /// the whole line: the bare service name prefixes every hashed one.
        init?(record: String, serviceLine: String) {
            let lines = record.split(separator: "\n")
            guard let path = lines.first, path.hasSuffix("\""),
                  lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == serviceLine })
            else { return nil }
            keychain = String(path.dropLast())
            account = record.firstMatch(of: /"acct"<blob>="([^"\n]*)"/).map { String($0.1) }
            modified = ClaudeKeychainCLI.modificationStamp(in: record)
        }
    }

    public static func runProcess(command: String, arguments: [String]) throws -> ProcessRunResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain both pipes concurrently, then wait: a child blocks once either
        // pipe's 64 KB buffer fills, and reading them in turn deadlocks when it
        // fills the one not being read.
        let errorHandle = stderr.fileHandleForReading
        let errorOutput = OSAllocatedUnfairLock(initialState: Data())
        let errorDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let data = errorHandle.readDataToEndOfFile()
            errorOutput.withLock { $0 = data }
            errorDrained.signal()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        process.waitUntilExit()
        return ProcessRunResult(
            exitCode: process.terminationStatus, stdout: output, stderr: errorOutput.withLock { $0 })
    }

    private static func mappedResult(
        _ result: ProcessRunResult,
        fallback: (String) -> KeychainReadResult,
        service: String,
        account: String?
    ) -> KeychainReadResult {
        if isNotFound(result) { return .notFound }
        guard result.exitCode == 0 else { return fallback(service) }
        guard let data = credentialsData(from: result.stdout) else {
            // The read worked and already mirrors SecItem's duplicate
            // selection, so falling back would only add a consent prompt:
            // an item holding something else counts as empty.
            let isJSON = (try? JSONSerialization.jsonObject(with: result.stdout.removingTrailingNewlines())) != nil
            Log.keychain.error("""
                keychain item \(service, privacy: .public) (account \(account ?? "any", privacy: .public)) \
                holds no Claude credential (\(result.stdout.count) bytes, JSON: \(isJSON))
                """)
            return .notFound
        }
        return .found(data)
    }

    private static func isNotFound(_ result: ProcessRunResult) -> Bool {
        result.exitCode == notFoundExitCode || stderrSaysNotFound(result.stderr)
    }

    private static func stderrSaysNotFound(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.localizedCaseInsensitiveContains("could not be found")
    }

    private static func credentialsData(from stdout: Data) -> Data? {
        let trimmed = stdout.removingTrailingNewlines()
        if let text = String(data: trimmed, encoding: .utf8) {
            let data = Data(text.utf8)
            if isCredentialsJSON(data) { return data }
        }
        guard let decoded = hexDecodedData(from: stdout), isCredentialsJSON(decoded) else { return nil }
        return decoded
    }

    private static func isCredentialsJSON(_ data: Data) -> Bool {
        (try? ClaudeCredentials.parse(data)) != nil
    }

    private static func hexDecodedData(from output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let hexBytes = text.utf8.filter { !isASCIIWhitespace($0) }
        guard !hexBytes.isEmpty, hexBytes.count.isMultiple(of: 2) else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(hexBytes.count / 2)
        var index = hexBytes.startIndex
        while index < hexBytes.endIndex {
            let next = hexBytes.index(after: index)
            guard let high = hexNibble(hexBytes[index]), let low = hexNibble(hexBytes[next]) else { return nil }
            decoded.append(high << 4 | low)
            index = hexBytes.index(after: next)
        }
        return Data(decoded)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

private extension Data {
    func removingTrailingNewlines() -> Data {
        var bytes = Array(self)
        while bytes.last == 10 || bytes.last == 13 {
            bytes.removeLast()
        }
        return Data(bytes)
    }
}
