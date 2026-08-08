import Foundation

enum ProcessRunner {
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func register(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            process?.terminate()
            lock.unlock()
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

    private static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

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
            inputPipe.fileHandleForWriting.write(stdin)
            try inputPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        handle?.register(process)

        let stdoutAccumulator = OutputAccumulator()
        let stderrAccumulator = OutputAccumulator()
        let group = DispatchGroup()

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading

        func drainPipe(_ handle: FileHandle, accumulator: OutputAccumulator) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                if !data.isEmpty {
                    let chunk = decodeText(data)
                    accumulator.append(chunk)
                    onOutputChunk?(chunk)
                }
                group.leave()
            }
        }

        drainPipe(stdoutHandle, accumulator: stdoutAccumulator)
        drainPipe(stderrHandle, accumulator: stderrAccumulator)

        try process.run()
        process.waitUntilExit()
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
            inputPipe.fileHandleForWriting.write(stdin)
            try inputPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        handle?.register(process)

        let outHandle = outputPipe.fileHandleForReading
        let errHandle = errorPipe.fileHandleForReading
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = outHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = errHandle.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return Output(
            stdout: decodeText(stdoutData),
            stderr: decodeText(stderrData),
            exitCode: process.terminationStatus,
            wasCancelled: handle?.wasCancelled ?? false
        )
    }
}