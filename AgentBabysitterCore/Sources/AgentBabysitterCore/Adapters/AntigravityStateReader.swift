import Foundation
import SQLite3

/// Pulls account status — plan tier AND per-model five-hour quota — out of
/// the Antigravity IDE's `state.vscdb`.
///
/// The value under `antigravityUnifiedStateSync.userStatus` is base64 of a
/// protobuf whose one string field is *itself* base64 of the real UserStatus
/// protobuf. Inside that:
///   - the plan appears as a tier-id string ("g1-pro-tier") followed by a
///     display name ("Google AI Pro");
///   - field 33 repeats model entries: `1:` model name, `15:` quota message
///     `{1: remaining fraction (0–1 double), 2: {1: reset epoch seconds}}`.
///     Verified against the app's own Model Quota page: the fraction and
///     reset match the "Five Hour Limit" it displays.
/// Every step is best-effort — any failure returns nil/empty and the row
/// falls back to plan-only or "not shared".
enum AntigravityStateReader {

    struct AccountStatus: Equatable {
        var plan: String?
        var fiveHourUsedPercent: Double?
        var fiveHourResetsAt: Date?
    }

    static func accountStatus(inStateDB dbData: Data) -> AccountStatus? {
        guard let value = readItemTableValue(dbData, key: "antigravityUnifiedStateSync.userStatus"),
              let outer = Data(base64Encoded: value) else { return nil }
        for payload in [outer] + innerPayloads(in: outer) {
            let status = accountStatus(fromProtobuf: payload)
            if status.plan != nil || status.fiveHourUsedPercent != nil { return status }
        }
        return nil
    }

    static func planName(inStateDB dbData: Data) -> String? {
        accountStatus(inStateDB: dbData)?.plan
    }

    /// Extraction core (unit-tested against synthetic and real payloads).
    static func accountStatus(fromProtobuf data: Data) -> AccountStatus {
        var status = AccountStatus()
        scan(data, depth: 0, into: &status)
        return status
    }

    // MARK: - Protobuf walking

    private enum ProtoValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    /// Parses one message; nil unless the entire buffer parses cleanly, so
    /// arbitrary strings/garbage are rejected rather than misread.
    private static func parseMessage(_ data: Data) -> [(field: Int, value: ProtoValue)]? {
        let bytes = [UInt8](data)
        var i = 0
        var out: [(Int, ProtoValue)] = []
        while i < bytes.count {
            guard let (tag, n) = varint(bytes, at: i) else { return nil }
            i = n
            let field = Int(tag >> 3)
            guard field > 0, field <= 500 else { return nil }
            switch tag & 7 {
            case 0:
                guard let (v, n) = varint(bytes, at: i) else { return nil }
                out.append((field, .varint(v))); i = n
            case 1:
                guard i + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for k in (0..<8).reversed() { v = v << 8 | UInt64(bytes[i + k]) }
                out.append((field, .fixed64(v))); i += 8
            case 5:
                guard i + 4 <= bytes.count else { return nil }
                var v: UInt32 = 0
                for k in (0..<4).reversed() { v = v << 8 | UInt32(bytes[i + k]) }
                out.append((field, .fixed32(v))); i += 4
            case 2:
                guard let (length, n) = varint(bytes, at: i),
                      length <= UInt64(bytes.count), n + Int(length) <= bytes.count else { return nil }
                out.append((field, .bytes(Data(bytes[n..<n + Int(length)])))); i = n + Int(length)
            default:
                return nil
            }
        }
        return out
    }

    private static func varint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < bytes.count, shift < 64 {
            let byte = bytes[i]; i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
        }
        return nil
    }

    private static func scan(_ data: Data, depth: Int, into status: inout AccountStatus) {
        guard depth < 12, let fields = parseMessage(data) else { return }

        // Plan: a message whose field 1 is "<x>-tier" and field 2 the name.
        if status.plan == nil,
           let tier = string(fields, field: 1), tier.hasSuffix("-tier"),
           let display = string(fields, field: 2), display.first?.isLetter == true {
            status.plan = display
        }

        // Quota entry: field 1 = model name, field 15 = {1: remaining, 2: {1: reset}}.
        // The most-consumed model group governs the row.
        if let name = string(fields, field: 1), !name.isEmpty,
           let quota = bytes(fields, field: 15), let quotaFields = parseMessage(quota),
           let remaining = double(quotaFields, field: 1), (0.0...1.0).contains(remaining) {
            let used = (1 - remaining) * 100
            if used > (status.fiveHourUsedPercent ?? -1) {
                status.fiveHourUsedPercent = used
                status.fiveHourResetsAt = nil
                if let reset = bytes(quotaFields, field: 2), let resetFields = parseMessage(reset),
                   case .varint(let epoch)? = resetFields.first(where: { $0.field == 1 })?.value,
                   (1_600_000_000...4_000_000_000).contains(epoch) {
                    status.fiveHourResetsAt = Date(timeIntervalSince1970: Double(epoch))
                }
            }
        }

        for (_, value) in fields {
            if case .bytes(let inner) = value, inner.count > 4 {
                scan(inner, depth: depth + 1, into: &status)
            }
        }
    }

    private static func string(_ fields: [(field: Int, value: ProtoValue)], field: Int) -> String? {
        guard case .bytes(let data)? = fields.first(where: { $0.field == field })?.value,
              let text = String(data: data, encoding: .utf8),
              text.allSatisfy({ $0.isASCII && !$0.isNewline }) else { return nil }
        return text
    }

    private static func bytes(_ fields: [(field: Int, value: ProtoValue)], field: Int) -> Data? {
        guard case .bytes(let data)? = fields.first(where: { $0.field == field })?.value else {
            return nil
        }
        return data
    }

    /// The remaining fraction is stored as float32 in the real payload;
    /// accept fixed64 doubles too for robustness.
    private static func double(_ fields: [(field: Int, value: ProtoValue)], field: Int) -> Double? {
        switch fields.first(where: { $0.field == field })?.value {
        case .fixed64(let raw): return Double(bitPattern: raw)
        case .fixed32(let raw): return Double(Float(bitPattern: raw))
        default: return nil
        }
    }

    // MARK: - Inner payload discovery

    /// The real UserStatus is base64 nested in a string field of the outer
    /// protobuf. Prefer proper walking; fall back to scanning for the longest
    /// base64 run at every 4-byte alignment (the run isn't 4-aligned).
    private static func innerPayloads(in outer: Data) -> [Data] {
        var results: [Data] = []
        if let fields = parseMessage(outer) {
            collectBase64Strings(fields, depth: 0, into: &results)
        }
        results.append(contentsOf: alignmentScanDecodes(in: outer))
        return results
    }

    private static func collectBase64Strings(_ fields: [(field: Int, value: ProtoValue)],
                                             depth: Int, into results: inout [Data]) {
        guard depth < 6 else { return }
        for (_, value) in fields {
            guard case .bytes(let data) = value else { continue }
            if data.count > 100, let text = String(data: data, encoding: .utf8),
               text.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) {
                let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
                if let decoded = Data(base64Encoded: padded) { results.append(decoded) }
            } else if let inner = parseMessage(data) {
                collectBase64Strings(inner, depth: depth + 1, into: &results)
            }
        }
    }

    private static func alignmentScanDecodes(in data: Data) -> [Data] {
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
}
