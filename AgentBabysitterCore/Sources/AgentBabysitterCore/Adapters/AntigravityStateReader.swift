import Foundation
import SQLite3

/// Pulls the plan tier out of the Antigravity IDE's `state.vscdb`.
///
/// The value under `antigravityUnifiedStateSync.userStatus` is base64 of a
/// protobuf whose one string field is *itself* base64 of the real UserStatus
/// protobuf; inside that, the plan tier appears as a tier-id string
/// ("g1-pro-tier") immediately followed by a human display name
/// ("Google AI Pro"). Every step is best-effort — any failure returns nil and
/// the row falls back to "not shared".
enum AntigravityStateReader {

    static func planName(inStateDB dbData: Data) -> String? {
        guard let value = readItemTableValue(dbData, key: "antigravityUnifiedStateSync.userStatus"),
              let outer = Data(base64Encoded: value) else { return nil }
        if let plan = planName(fromProtobuf: outer) { return plan }
        // The real UserStatus is base64 nested inside the outer protobuf as a
        // string field; the run isn't 4-aligned, so try every alignment.
        for inner in innerBase64Decodes(in: outer) {
            if let plan = planName(fromProtobuf: inner) { return plan }
        }
        return nil
    }

    /// Extraction core (unit-tested): find a "<id>-tier" string, return the
    /// protobuf string field that follows it as the display name.
    static func planName(fromProtobuf data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let tierRange = range(of: Array("-tier".utf8), in: bytes) else { return nil }
        // A protobuf string field is: tag byte, length varint, then bytes.
        // The display name is the next length-prefixed ASCII string after the
        // tier id ends. Scan forward for the first plausible one.
        var i = tierRange.upperBound
        while i < bytes.count - 2 {
            // field tag 0x12 (field 2, wire type 2 = length-delimited) commonly
            // carries the display name; accept any length-delimited string.
            if bytes[i] == 0x12 {
                let length = Int(bytes[i + 1])
                let start = i + 2
                if (3...64).contains(length), start + length <= bytes.count {
                    let candidate = bytes[start..<start + length]
                    if candidate.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
                       let name = String(bytes: candidate, encoding: .utf8),
                       name.first?.isLetter == true {
                        return name
                    }
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - SQLite

    private static func readItemTableValue(_ dbData: Data, key: String) -> String? {
        // Write to a temp file — SQLite needs a path; the file is our own copy.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-state-\(UUID().uuidString).vscdb")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? dbData.write(to: tmp)) != nil else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: c)
    }

    // MARK: - byte helpers

    /// Decode the longest base64-looking run at each of the 4 byte alignments
    /// (the run is embedded mid-protobuf and isn't 4-aligned). Returns every
    /// successful decode for the caller to scan.
    private static func innerBase64Decodes(in data: Data) -> [Data] {
        let b64chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var best: Range<Int>?
        var runStart: Int?
        let bytes = [UInt8](data)
        for i in 0...bytes.count {
            let inRun = i < bytes.count && (b64chars.contains(bytes[i]) || bytes[i] == 0x3d)
            if inRun, runStart == nil { runStart = i }
            else if !inRun, let start = runStart {
                if (best.map { $0.count } ?? 0) < i - start { best = start..<i }
                runStart = nil
            }
        }
        guard let range = best, range.count >= 100 else { return [] }
        let run = Array(bytes[range])
        var results: [Data] = []
        for offset in 0..<4 {
            guard offset < run.count else { break }
            let trimmed = Array(run[offset...])
            let aligned = trimmed.prefix(trimmed.count - trimmed.count % 4)
            if let decoded = Data(base64Encoded: Data(aligned)) { results.append(decoded) }
        }
        return results
    }

    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return start..<start + needle.count
            }
        }
        return nil
    }
}

