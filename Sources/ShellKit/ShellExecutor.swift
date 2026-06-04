import Foundation

// MARK: - ShellCommandResult

/// Immutable result of a shell command execution.
public struct ShellCommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let duration: TimeInterval

    public init(exitCode: Int32, stdout: Data, stderr: Data, duration: TimeInterval) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }

    /// Convenience: stdout decoded as UTF-8, trimmed.
    public var stdoutString: String {
        (String(data: stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience: stderr decoded as UTF-8, trimmed.
    public var stderrString: String {
        (String(data: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ShellError

public enum ShellError: Error, Sendable {
    /// Process exceeded the timeout; was SIGKILLed.
    case timeout(args: [String], limit: TimeInterval)
    /// Process failed to launch (posix_spawn error).
    case launchFailed(args: [String], underlying: String)
}

// MARK: - ShellExecutorProtocol
//
// NOTE: This is the NEW canonical protocol introduced by the TimedShellExecutor
// architectural fix (W1). It is intentionally named `ShellExecutorProtocol` to
// avoid collision with the existing `ShellExecutor` protocol in
// Sources/ShiKit/Ingest/VideoMetadataExtractor.swift which has a different
// signature and is Ingest-scoped. Both protocols coexist; the Ingest-scoped
// one will be migrated in W2/W3.

public protocol ShellExecutorProtocol: Sendable {
    /// Execute a command.
    ///
    /// - Parameters:
    ///   - args: Full argument list, e.g. `["git", "-C", path, "status"]`.
    ///           The first element is looked up via `/usr/bin/env`.
    ///   - cwd:  Working directory; nil = inherit caller's.
    ///   - env:  Extra environment variables merged into the current process env.
    ///   - timeout: Hard wall-clock limit in seconds. Process is SIGTERMed then
    ///              SIGKILLed after the grace period if it does not exit.
    ///   - stdin: Optional data to pipe into the process's stdin.
    /// - Returns: ``ShellCommandResult`` on success (any exit code, including non-zero).
    /// - Throws: ``ShellError.timeout`` if the process exceeds `timeout`.
    ///           ``ShellError.launchFailed`` if `posix_spawn` fails.
    func run(
        _ args: [String],
        cwd: String?,
        env: [String: String]?,
        timeout: TimeInterval,
        stdin: Data?
    ) async throws -> ShellCommandResult
}
