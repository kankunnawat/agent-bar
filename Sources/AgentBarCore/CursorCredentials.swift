import Foundation
import SQLite3

/// Read-only access to Cursor's VS Code-style key/value store.
public enum CursorStateDB {
    /// One `ItemTable` value, opened read-only so Cursor's file is never
    /// written or created. nil on a missing file or an absent key; throws
    /// when the file exists but cannot be read (locked, corrupt), so the row
    /// says so instead of "not signed in". Failures log the SQLite message,
    /// never the value.
    public static func read(dbPath: String, key: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var result = query(dbPath, flags: SQLITE_OPEN_READONLY, key: key)
        // A WAL database whose -wal/-shm sidecars are gone (clean last close)
        // cannot be opened read-only: SQLite needs to create the -shm file.
        // With no -wal there is no uncheckpointed data, so read the main file
        // as immutable, which creates nothing in Cursor's directory.
        if case .failure(SQLITE_CANTOPEN, _) = result,
           !FileManager.default.fileExists(atPath: dbPath + "-wal") {
            let uri = URL(fileURLWithPath: dbPath).absoluteString + "?mode=ro&immutable=1"
            result = query(uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, key: key)
        }
        switch result {
        case .value(let value): return value
        case .failure(_, let message):
            Log.fetch.error("cursor state db read failed: \(message, privacy: .public)")
            throw FetchError.credentialsMissing("Cursor login database unreadable — reopen Cursor")
        }
    }

    private enum Outcome {
        case value(String?)
        case failure(Int32, String)
    }

    private static func query(_ filename: String, flags: Int32, key: String) -> Outcome {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK else { return failure(db) }
        // Wait out a checkpoint or WAL recovery instead of failing the tick.
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return failure(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return .value(sqlite3_column_text(stmt, 0).map { String(cString: $0) })
        case SQLITE_DONE: return .value(nil)
        default: return failure(db)
        }
    }

    private static func failure(_ db: OpaquePointer?) -> Outcome {
        .failure(sqlite3_errcode(db) & 0xFF, String(cString: sqlite3_errmsg(db)))
    }
}

/// Cursor login read from its local state. Read-only by design: Cursor
/// refreshes its own token, and a refresh here would rotate it.
public struct CursorCredentials: Sendable, Equatable {
    public typealias StateRead = @Sendable (_ dbPath: String, _ key: String) throws -> String?

    public static let databaseSubpath = "User/globalStorage/state.vscdb"

    public var accessToken: String
    /// `sub` claim after its last "|" — the id the session cookie expects.
    public var userID: String
    public var expiresAt: Date?
    public var membershipType: String?

    public func isExpired(now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    public static func load(
        cursorDir: String, read: StateRead = { try CursorStateDB.read(dbPath: $0, key: $1) }
    ) throws -> CursorCredentials {
        let dbPath = URL(fileURLWithPath: cursorDir).appendingPathComponent(databaseSubpath).path
        guard let token = try read(dbPath, "cursorAuth/accessToken"), !token.isEmpty else {
            throw FetchError.signedOut
        }
        guard let claims = payload(of: token),
              let sub = claims["sub"] as? String,
              let userID = sub.split(separator: "|").last.map(String.init), !userID.isEmpty
        else { throw FetchError.credentialsMissing("Cursor login unreadable — sign in to Cursor again") }
        let expiresAt = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        // The plan name is only a fallback for the API's own, so a failed
        // read must not fail the load while a valid token is in hand.
        return CursorCredentials(
            accessToken: token, userID: userID, expiresAt: expiresAt,
            membershipType: try? read(dbPath, "cursorAuth/stripeMembershipType"))
    }

    /// True only when no login is stored, so a new row can start signed out
    /// instead of flashing "loading" at launch. Any other failure is false:
    /// the first refresh surfaces it as an error row.
    public static func isSignedOut(
        cursorDir: String, read: StateRead = { try CursorStateDB.read(dbPath: $0, key: $1) }
    ) -> Bool {
        do {
            _ = try load(cursorDir: cursorDir, read: read)
            return false
        } catch FetchError.signedOut {
            return true
        } catch {
            return false
        }
    }

    private static func payload(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
