import Foundation

/// Per-process cumulative network bytes via nettop — the real-time
/// activity signal for cloud-streaming desktop agents whose files don't
/// record completion. nettop has been observed HANGING when launched from
/// a GUI app context, so every invocation gets a hard watchdog; callers
/// must still sample off-actor (see SessionStore's probe loop).
public enum ProcessNetworkSampler {

    /// nettop's first `-l 1` sample lands ~5.05 s after launch (measured
    /// repeatedly on this machine: 5.06–5.07 s, and independent of `-s`, which
    /// only spaces *later* samples). The watchdog must clear that or it kills
    /// nettop before it prints its single data row — which is exactly what a
    /// 2 s watchdog did, so the signal never fired. 8 s clears the real
    /// latency with margin while still bounding a genuinely stuck nettop.
    private static let watchdogSeconds: Double = 8

    public static func cumulativeBytes(pid: Int32) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // `-l 1` prints one snapshot whose bytes_in/bytes_out are cumulative
        // since process start, then exits — one sample is all we need.
        process.arguments = ["-P", "-p", String(pid), "-x", "-l", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdogSeconds, execute: watchdog)
        // Output is one header + one data row (<300 B), far under the pipe
        // buffer, so a single blocking read to EOF cannot deadlock; it unblocks
        // when nettop exits (~5 s) or the watchdog terminates it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parse(output)
    }

    /// Last data row: time, name, bytes_in, bytes_out, …
    public static func parse(_ output: String) -> Int? {
        for line in output.split(separator: "\n").reversed() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[1].contains("."),
                  let bytesIn = Int(fields[2]), let bytesOut = Int(fields[3]) else { continue }
            return bytesIn + bytesOut
        }
        return nil
    }
}
