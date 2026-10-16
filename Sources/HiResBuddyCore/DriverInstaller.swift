import Foundation

/// Runs the driver's `install.sh` from the app bundle (`Contents/Resources/driver/`, with `build/HiResBuddy.driver`)
/// as root via an administrator password prompt.
enum DriverInstaller {
    enum Failure: Error, CustomStringConvertible {
        case notBundled
        case failed(String)

        var description: String {
            switch self {
            case .notBundled: return "Драйвер не входит в эту сборку: driver/build.sh, затем scripts/bundle.sh"
            case .failed(let why): return "Установка не удалась: \(why)"
            }
        }
    }

    static func install() async throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("driver"),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("install.sh").path) else {
            throw Failure.notBundled
        }
        try await Task.detached { try run(from: source) }.value
    }

    private static func run(from source: URL) throws {
        // Root cannot read ~/Downloads, ~/Desktop or ~/Documents (TCC): run a copy from the temporary directory.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hiresbuddy-driver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        do { try FileManager.default.copyItem(at: source, to: copy) } catch { throw Failure.failed("\(error)") }
        let script = copy.appendingPathComponent("install.sh").path.replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script quoted form of \"\(script)\" with administrator privileges"]
        let stderr = Pipe()
        process.standardError = stderr
        do { try process.run() } catch { throw Failure.failed("\(error)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
