import Foundation
import Testing
@testable import AgentBarCore

private let cliFixture = #"{"claudeAiOauth":{"accessToken":"tok-cli","subscriptionType":"max"}}"#

@Suite struct ClaudeKeychainCLITests {
    @Test func happyPathReturnsCredentialsData() throws {
        var calls: [[String]] = []
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { command, arguments in
                #expect(command == "/usr/bin/security")
                calls.append(arguments)
                if arguments == ["list-keychains"] { return searchList("/login.keychain-db") }
                return ProcessRunResult(exitCode: 0, stdout: Data((cliFixture + "\n").utf8), stderr: Data())
            },
            secItemRead: { _ in .denied(-1) })

        #expect(calls == [["list-keychains"], ["find-generic-password", "-s", "svc", "-a", "me", "-w"]])
        guard case .found(let data) = result else {
            #expect(result == .found(Data(cliFixture.utf8)))
            return
        }
        #expect(try ClaudeCredentials.parse(data).accessToken == "tok-cli")
    }

    @Test func hexOutputReturnsDecodedCredentialsData() throws {
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, _ in
                ProcessRunResult(exitCode: 0, stdout: hexEncoded(cliFixture), stderr: Data())
            },
            secItemRead: { _ in .denied(-1) })

        guard case .found(let data) = result else {
            #expect(result == .found(Data(cliFixture.utf8)))
            return
        }
        #expect(try ClaudeCredentials.parse(data).accessToken == "tok-cli")
    }

    @Test func notFoundExitCodeMapsToNotFound() {
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, _ in
                ProcessRunResult(exitCode: 44, stdout: Data(), stderr: Data("could not be found\n".utf8))
            },
            secItemRead: { _ in .denied(-1) })

        #expect(result == .notFound)
    }

    /// With no own item `security` returns the first item on the service in
    /// a keychain, not the newest (reproduced 2026-10-14 in a scratch
    /// keychain: the older of two accounts came first). The newer decoys sit
    /// on another service and on a hashed name the bare one prefixes.
    @Test func missingOwnItemReadsNewestItemOfAnyAccount() {
        let security = FakeSecurity(keychains: ["/login.keychain-db", "/work.keychain-db"], items: [
            .init("/login.keychain-db", "svc", "zed", "20261002000000"),
            .init("/login.keychain-db", "svc", "amy", "20261010000000"),
            .init("/login.keychain-db", "svc", "bob", "20261009000000"),
            .init("/login.keychain-db", "other-svc", "kim", "20261013000000"),
            .init("/login.keychain-db", "svc-deadbeef", "lee", "20261014000000"),
            .init("/work.keychain-db", "svc", "cy", "20261008000000"),
        ])
        var secretReads: [[String]] = []
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, arguments in
                if arguments.contains("-w") { secretReads.append(arguments) }
                return security.run(arguments)
            },
            secItemRead: { _ in .denied(-1) })

        #expect(secretReads.last == ["find-generic-password", "-s", "svc", "-a", "amy", "-w", "/login.keychain-db"])
        #expect(token(result) == "amy@20261010000000")
    }

    /// Like `ClaudeKeychain.select`, an own item wins even when it holds no
    /// Claude credential: falling through to a newer foreign item would show
    /// another account's usage.
    @Test func ownItemWithoutCredentialSkipsOtherAccounts() {
        let security = FakeSecurity(keychains: ["/login.keychain-db"], items: [
            .init("/login.keychain-db", "svc", "me", "20261002000000"),
            .init("/login.keychain-db", "svc", "amy", "20261010000000"),
        ])
        var secretReads: [[String]] = []
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, arguments in
                guard arguments.contains("-w") else { return security.run(arguments) }
                secretReads.append(arguments)
                guard arguments.contains("me") else { return security.run(arguments) }
                return ProcessRunResult(exitCode: 0, stdout: Data(#"{"mcpOAuth":{}}"#.utf8), stderr: Data())
            },
            secItemRead: { _ in .denied(-1) })

        #expect(result == .notFound)
        #expect(secretReads == [["find-generic-password", "-s", "svc", "-a", "me", "-w"]])
    }

    /// The dump reads every item's attributes, so a service with no item at
    /// all must not trigger it.
    @Test func missingServiceSkipsKeychainDump() {
        let security = FakeSecurity(keychains: ["/login.keychain-db"], items: [
            .init("/login.keychain-db", "svc-deadbeef", "me", "20261014000000"),
        ])
        var calls: [[String]] = []
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, arguments in
                calls.append(arguments)
                return security.run(arguments)
            },
            secItemRead: { _ in .denied(-1) })

        #expect(result == .notFound)
        #expect(!calls.contains { $0.first == "dump-keychain" })
    }

    @Test func unreadableKeychainDumpReadsFirstMatch() {
        let security = FakeSecurity(keychains: ["/login.keychain-db"], items: [
            .init("/login.keychain-db", "svc", "zed", "20261002000000"),
            .init("/login.keychain-db", "svc", "amy", "20261010000000"),
        ])
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, arguments in
                guard arguments.first == "dump-keychain" else { return security.run(arguments) }
                return ProcessRunResult(exitCode: 1, stdout: Data(), stderr: Data())
            },
            secItemRead: { _ in .denied(-1) })

        #expect(token(result) == "zed@20261002000000")
    }

    /// A keychain holds one item per service and account, so same-account
    /// duplicates sit in different keychains, and `security` alone returns
    /// the one in the first keychain of the search list even when it is older.
    @Test func sameAccountDuplicateReadsNewestKeychain() {
        let security = FakeSecurity(
            keychains: ["/old.keychain-db", "/new.keychain-db", "/System.keychain"],
            items: [
                .init("/old.keychain-db", "svc", "me", "20261001000000"),
                .init("/new.keychain-db", "svc", "me", "20261014000000"),
            ])
        var secretReads: [[String]] = []
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, arguments in
                if arguments.contains("-w") { secretReads.append(arguments) }
                return security.run(arguments)
            },
            secItemRead: { _ in .denied(-1) })

        #expect(secretReads == [["find-generic-password", "-s", "svc", "-a", "me", "-w", "/new.keychain-db"]])
        #expect(token(result) == "me@20261014000000")
    }

    /// A clean read of non-credential content must not fall back to SecItem:
    /// that only adds a consent prompt macOS 26 re-shows every read.
    @Test func successfulReadOfNonCredentialContentDoesNotFallBack() {
        var fellBack = false
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, _ in
                ProcessRunResult(exitCode: 0, stdout: Data(#"{"mcpOAuth":{}}"#.utf8), stderr: Data())
            },
            secItemRead: { _ in
                fellBack = true
                return .denied(-1)
            })

        #expect(!fellBack)
        #expect(result == .notFound)
    }

    @Test func unexpectedFailureFallsBackToSecItemRead() {
        var fallbackService: String?
        let result = ClaudeKeychainCLI.readGenericPassword(
            service: "svc",
            account: "me",
            processRunner: { _, _ in
                ProcessRunResult(exitCode: 1, stdout: Data("garbage".utf8), stderr: Data())
            },
            secItemRead: { service in
                fallbackService = service
                return .denied(-25293)
            })

        #expect(fallbackService == "svc")
        #expect(result == .denied(-25293))
    }

    /// Output past the 64 KB pipe buffer on either pipe must not deadlock;
    /// stderr is filled first so draining stdout alone still hangs. `alarm 5`
    /// kills a child stuck on a full pipe, so a regression fails, not hangs.
    @Test func runProcessReadsOutputLargerThanPipeBuffer() throws {
        let result = try ClaudeKeychainCLI.runProcess(
            command: "/usr/bin/perl",
            arguments: ["-e", #"alarm 5; print STDERR "e" x 200000; print "x" x 200000"#])

        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.count == 200_000)
    }

    private func searchList(_ keychains: String...) -> ProcessRunResult {
        let text = keychains.map { "    \"\($0)\"\n" }.joined()
        return ProcessRunResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
    }

    private func token(_ result: KeychainReadResult) -> String? {
        guard case .found(let data) = result else { return nil }
        return try? ClaudeCredentials.parse(data).accessToken
    }

    private func hexEncoded(_ string: String) -> Data {
        let hex = Data(string.utf8).map { String(format: "%02x", $0) }.joined()
        return Data((hex + "\n").utf8)
    }
}

/// Stand-in for `/usr/bin/security` behaving as seen live: one item per
/// service and account in a keychain, matches in search-list then insertion
/// order, the first one returned. A secret's token is "<account>@<mdat>".
private struct FakeSecurity {
    struct Item {
        let keychain: String
        let service: String
        let account: String
        let modified: String

        init(_ keychain: String, _ service: String, _ account: String, _ modified: String) {
            self.keychain = keychain
            self.service = service
            self.account = account
            self.modified = modified
        }
    }

    let keychains: [String]
    let items: [Item]

    func run(_ arguments: [String]) -> ProcessRunResult {
        if arguments == ["list-keychains"] {
            return output(keychains.map { "    \"\($0)\"\n" }.joined())
        }
        let named = arguments.filter { $0.hasPrefix("/") }
        let searched = (named.isEmpty ? keychains : named).flatMap { keychain in
            items.filter { $0.keychain == keychain }
        }
        if arguments.first == "dump-keychain" { return output(searched.map(record).joined()) }
        let service = value(after: "-s", in: arguments)
        let account = value(after: "-a", in: arguments)
        guard let match = searched.first(where: {
            $0.service == service && (account == nil || $0.account == account)
        }) else {
            return ProcessRunResult(exitCode: 44, stdout: Data(), stderr: Data())
        }
        guard arguments.contains("-w") else { return output(record(match)) }
        return output(#"{"claudeAiOauth":{"accessToken":"\#(match.account)@\#(match.modified)"}}"# + "\n")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    /// One trimmed `dump-keychain` record, also the attribute output of a
    /// read without `-w`. Every "cdat" is the same, so only "mdat" ranks.
    private func record(_ item: Item) -> String {
        let hex = Data((item.modified + "Z").utf8).map { String(format: "%02X", $0) }.joined()
        return """
            keychain: "\(item.keychain)"
            version: 512
            class: "genp"
            attributes:
                0x00000007 <blob>="\(item.service)"
                "acct"<blob>="\(item.account)"
                "cdat"<timedate>=0x00  "20260101000000Z\\000"
                "mdat"<timedate>=0x\(hex)00  "\(item.modified)Z\\000"
                "svce"<blob>="\(item.service)"

            """
    }

    private func output(_ text: String) -> ProcessRunResult {
        ProcessRunResult(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
    }
}
