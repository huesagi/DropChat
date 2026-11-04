import Foundation

/// Runs a command-line tool the way Droppy's Good Citizen guide asks: never
/// blocking the caller, reading output while the tool runs, with a deadline,
/// and stopping the tool's whole process group on timeout or cancellation.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public enum Failure: LocalizedError {
        case launch(String)

        public var errorDescription: String? {
            switch self {
            case .launch(let message): return "The command could not start: \(message)"
            }
        }
    }

    /// The environment a GUI app's child gets is minimal; add the usual tool
    /// locations so `npx`, `uvx`, `python3` and Homebrew binaries resolve.
    public static func augmentedEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (paths + existing).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Resolves a bare command name against the augmented PATH.
    public static func resolveExecutable(_ command: String, environment: [String: String]) -> URL? {
        if command.contains("/") {
            let url = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func run(
        _ executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(60),
        maxOutputBytes: Int = 1_000_000
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment ?? augmentedEnvironment()
        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        let (exits, exit) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in
            exit.yield(())
            exit.finish()
        }
        do {
            try process.run()
        } catch {
            throw Failure.launch(error.localizedDescription)
        }
        if let stdin {
            let handle = input.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                handle.write(stdin)
                try? handle.close()
            }
        }

        // Process puts the tool in a process group of its own; a negative pid
        // signals the tool and everything it started, never Droppy.
        let group = -process.processIdentifier
        let timedOut = TimeoutFlag()
        let deadline = Task {
            try await Task.sleep(for: timeout)
            timedOut.set()
            kill(group, SIGTERM)
            try await Task.sleep(for: .seconds(2))
            kill(group, SIGKILL)
        }
        defer { deadline.cancel() }

        return await withTaskCancellationHandler {
            async let stdoutData = readAll(out.fileHandleForReading, limit: maxOutputBytes)
            async let stderrData = readAll(err.fileHandleForReading, limit: maxOutputBytes)
            let (stdoutBytes, stderrBytes) = await (stdoutData, stderrData)
            for await _ in exits {}
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: stdoutBytes, as: UTF8.self),
                stderr: String(decoding: stderrBytes, as: UTF8.self),
                timedOut: timedOut.value
            )
        } onCancel: {
            kill(group, SIGTERM)
        }
    }

    /// Reads a pipe to its end on a queue of its own (never a cooperative thread).
    static func readAll(_ handle: FileHandle, limit: Int) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
                }
                continuation.resume(returning: data)
            }
        }
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = SyncLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
