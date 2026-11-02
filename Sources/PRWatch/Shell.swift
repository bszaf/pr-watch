import Foundation

/// Single-quote for the shell (handles spaces and embedded quotes).
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Run a process to completion; trimmed stdout on exit 0 (or any exit, when not
/// `requireSuccess`) with non-empty output, else nil.
/// Blocks the calling thread — from async code go through `runBlocking`.
func runCapturing(_ launch: String, _ args: [String], requireSuccess: Bool = true) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    // Drain before waiting: output beyond the 64 KB pipe buffer otherwise deadlocks both sides.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 || !requireSuccess else { return nil }
    let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Run blocking work (process spawns, login shells) on a GCD thread so it doesn't pin
/// one of Swift concurrency's fixed-size cooperative threads.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .utility).async { cont.resume(returning: work()) }
    }
}
