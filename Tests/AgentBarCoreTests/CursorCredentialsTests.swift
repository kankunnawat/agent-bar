import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

/// Unsigned JWT with the given payload; only the payload segment matters.
private func jwt(_ payload: String) -> String {
    let body = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
}

@Suite struct CursorCredentialsTests {
    let dir = "/tmp/fake-cursor"
    let dbPath = "/tmp/fake-cursor/User/globalStorage/state.vscdb"

    private func reader(_ values: [String: String]) -> CursorCredentials.StateRead {
        let expected = dbPath
        return { path, key in path == expected ? values[key] : nil }
    }

    @Test func loadsTokenUserIDExpiryAndPlan() throws {
        let token = jwt(#"{"sub":"github|user_01ABC","exp":1790000000}"#)
        let creds = try CursorCredentials.load(cursorDir: dir, read: reader([
            "cursorAuth/accessToken": token,
            "cursorAuth/stripeMembershipType": "pro_plus",
        ]))
        #expect(creds.accessToken == token)
        #expect(creds.userID == "user_01ABC")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(creds.membershipType == "pro_plus")
    }

    @Test func subWithoutPipeIsTheWholeUserID() throws {
        let creds = try CursorCredentials.load(cursorDir: dir, read: reader([
            "cursorAuth/accessToken": jwt(#"{"sub":"user_plain"}"#),
        ]))
        #expect(creds.userID == "user_plain")
        #expect(creds.expiresAt == nil)
        #expect(creds.membershipType == nil)
    }

    @Test func failedPlanReadStillLoads() throws {
        let token = jwt(#"{"sub":"a|b"}"#)
        let creds = try CursorCredentials.load(cursorDir: dir, read: { _, key in
            guard key == "cursorAuth/accessToken" else { throw FetchError.credentialsMissing("locked") }
            return token
        })
        #expect(creds.accessToken == token)
        #expect(creds.membershipType == nil)
    }

    @Test func missingOrEmptyTokenIsSignedOut() {
        #expect(throws: FetchError.signedOut) {
            try CursorCredentials.load(cursorDir: dir, read: reader([:]))
        }
        #expect(throws: FetchError.signedOut) {
            try CursorCredentials.load(cursorDir: dir, read: reader(["cursorAuth/accessToken": ""]))
        }
    }

    @Test func signedOutProbeIsTrueOnlyWithoutALogin() {
        #expect(CursorCredentials.isSignedOut(cursorDir: dir, read: reader([:])))
        #expect(!CursorCredentials.isSignedOut(cursorDir: dir, read: reader([
            "cursorAuth/accessToken": jwt(#"{"sub":"a|b"}"#),
        ])))
        // A broken login or database must reach the first refresh as an error row.
        #expect(!CursorCredentials.isSignedOut(cursorDir: dir, read: reader(["cursorAuth/accessToken": "not-a-jwt"])))
        let lockedDB: CursorCredentials.StateRead = { _, _ in
            throw FetchError.credentialsMissing("Cursor login database unreadable — reopen Cursor")
        }
        #expect(!CursorCredentials.isSignedOut(cursorDir: dir, read: lockedDB))
    }

    @Test func unreadableTokenAsksToSignIn() {
        #expect(throws: FetchError.credentialsMissing("Cursor login unreadable — sign in to Cursor again")) {
            try CursorCredentials.load(cursorDir: dir, read: reader(["cursorAuth/accessToken": "not-a-jwt"]))
        }
    }

    @Test func expiryComparesToNow() throws {
        let creds = try CursorCredentials.load(cursorDir: dir, read: reader([
            "cursorAuth/accessToken": jwt(#"{"sub":"a|b","exp":1000}"#),
        ]))
        #expect(creds.isExpired(now: Date(timeIntervalSince1970: 1000)))
        #expect(!creds.isExpired(now: Date(timeIntervalSince1970: 999)))
    }
}

@Suite struct CursorStateDBTests {
    /// Real SQLite file in a temp dir, WAL mode like Cursor's own database
    /// (verified live 2026-10-04: `journal_mode=wal`, value column TEXT).
    /// The writer stays open — as a running Cursor does — so the -wal/-shm
    /// files exist while the read-only reader opens the file. The space in
    /// the dir name mirrors "Application Support" for the URI retry path.
    /// The caller removes `dir` when done.
    private func makeDB(rows: [(String, String)]) throws -> (dir: URL, writer: OpaquePointer?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cursor db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        try #require(sqlite3_open(dbPath(in: dir), &db) == SQLITE_OK)
        var sql = "PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
        for (key, value) in rows { sql += "INSERT INTO ItemTable VALUES ('\(key)', '\(value)');" }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return (dir, db)
    }

    private func dbPath(in dir: URL) -> String {
        dir.appendingPathComponent("state.vscdb").path
    }

    @Test func readsValueByKeyWhileWriterIsOpen() throws {
        let fixture = try makeDB(rows: [("cursorAuth/accessToken", "tok"), ("other", "x")])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        defer { sqlite3_close(fixture.writer) }
        #expect(try CursorStateDB.read(dbPath: dbPath(in: fixture.dir), key: "cursorAuth/accessToken") == "tok")
    }

    @Test func absentKeyIsNil() throws {
        let fixture = try makeDB(rows: [("other", "x")])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        defer { sqlite3_close(fixture.writer) }
        #expect(try CursorStateDB.read(dbPath: dbPath(in: fixture.dir), key: "cursorAuth/accessToken") == nil)
    }

    @Test func readsCheckpointedDatabaseWithoutSidecarsAndCreatesNone() throws {
        let fixture = try makeDB(rows: [("cursorAuth/accessToken", "tok")])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let path = dbPath(in: fixture.dir)
        #expect(sqlite3_exec(fixture.writer, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(fixture.writer)
        let sidecars = [path + "-wal", path + "-shm"]
        for sidecar in sidecars { try? FileManager.default.removeItem(atPath: sidecar) }
        #expect(try CursorStateDB.read(dbPath: path, key: "cursorAuth/accessToken") == "tok")
        #expect(sidecars.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func unreadableFileThrowsInsteadOfNotSignedIn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).vscdb").path
        try Data("not a database, just text padded past one page".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: FetchError.credentialsMissing("Cursor login database unreadable — reopen Cursor")) {
            try CursorStateDB.read(dbPath: path, key: "k")
        }
    }

    @Test func missingFileIsNilAndCreatesNothing() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).vscdb").path
        #expect(try CursorStateDB.read(dbPath: path, key: "k") == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
