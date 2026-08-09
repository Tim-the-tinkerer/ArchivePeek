import Foundation

enum ProcessRunner {
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Register a process for cancellation. If cancel() already ran, terminate immediately
        /// so a late-started 7-Zip cannot run after the user cancelled during prepare.
        func register(_ process: Process) {
            lock.lock()
            self.process = process
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled {
                process.terminate()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            running?.terminate()
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let wasCancelled: Bool

        init(stdout: String, stderr: String, exitCode: Int32, wasCancelled: Bool = false) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.wasCancelled = wasCancelled
        }
    }

    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ chunk: String) {
            lock.lock()
            text += chunk
            lock.unlock()
        }

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    /// Thread-safe one-shot gate for pipe EOF / cleanup (Sendable for concurrent handlers).
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func runOnce(_ body: () -> Void) {
            lock.lock()
            let shouldRun = !done
            if shouldRun { done = true }
            lock.unlock()
            if shouldRun { body() }
        }
    }

    private static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Run a process and deliver stdout/stderr **as it arrives** (not only after EOF).
    /// Uses `readabilityHandler` + a final drain so progress parsers get live chunks.
    static func runMonitored(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment overrides: [String: String]? = nil,
        stdin: Data? = nil,
        handle: Handle? = nil,
        onOutputChunk: (@Sendable (String) -> Void)? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        var environment = ProcessInfo.processInfo.environment
        if let overrides {
            for (key, value) in overrides {
                environment[key] = value
            }
        }
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let stdin {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            // write(contentsOf:) writes the full buffer; the older write(_:) API could truncate.
            try inputPipe.fileHandleForWriting.write(contentsOf: stdin)
            try inputPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        handle?.register(process)
        if handle?.wasCancelled == true {
            return Output(stdout: "", stderr: "", exitCode: 15, wasCancelled: true)
        }

        let stdoutAccumulator = OutputAccumulator()
        let stderrAccumulator = OutputAccumulator()
        let group = DispatchGroup()
        // OnceFlag is @unchecked Sendable so concurrent readabilityHandlers can leave the group
        // without nested non-Sendable local functions (Swift 6 warning under 6.2+ compilers).
        let stdoutDone = OnceFlag()
        let stderrDone = OnceFlag()

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading

        group.enter()
        stdoutHandle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                stdoutDone.runOnce { group.leave() }
                return
            }
            let chunk = decodeText(data)
            stdoutAccumulator.append(chunk)
            onOutputChunk?(chunk)
        }

        group.enter()
        stderrHandle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                stderrDone.runOnce { group.leave() }
                return
            }
            let chunk = decodeText(data)
            stderrAccumulator.append(chunk)
            // 7-Zip often prints progress on stderr; surface it to the progress callback.
            onOutputChunk?(chunk)
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            stdoutDone.runOnce { group.leave() }
            stderrDone.runOnce { group.leave() }
            group.wait()
            throw error
        }

        // Cancel can race between wasCancelled check and run(); re-check and kill.
        if handle?.wasCancelled == true {
            process.terminate()
        }
        process.waitUntilExit()

        // Process finished: stop handlers and drain any remaining buffered bytes.
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        if let rest = try? stdoutHandle.readToEnd(), !rest.isEmpty {
            let chunk = decodeText(rest)
            stdoutAccumulator.append(chunk)
            onOutputChunk?(chunk)
        }
        if let rest = try? stderrHandle.readToEnd(), !rest.isEmpty {
            let chunk = decodeText(rest)
            stderrAccumulator.append(chunk)
            onOutputChunk?(chunk)
        }

        stdoutDone.runOnce { group.leave() }
        stderrDone.runOnce { group.leave() }
        group.wait()

        return Output(
            stdout: stdoutAccumulator.value,
            stderr: stderrAccumulator.value,
            exitCode: process.terminationStatus,
            wasCancelled: handle?.wasCancelled ?? false
        )
    }

    static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment overrides: [String: String]? = nil,
        stdin: Data? = nil,
        handle: Handle? = nil
    ) throws -> Output {
        // Non-progress paths can use the same streaming runner without a chunk callback.
        try runMonitored(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: overrides,
            stdin: stdin,
            handle: handle,
            onOutputChunk: nil
        )
    }
}
