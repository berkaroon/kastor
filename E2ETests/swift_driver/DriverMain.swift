import Foundation

@main
enum DriverMain {
    @MainActor
    static func main() {
        let allCases: [SwiftDriverCase] = (
            Tier1Cases.allCases +
            Tier2Cases.allCases +
            Tier3Cases.allCases +
            Tier4Cases.allCases
        )

        let args = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        if args.contains("--list") {
            let meta = allCases.map { $0.metadata }
            if let data = try? encoder.encode(meta),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                exit(0)
            }
            fputs("Failed to encode case metadata\n", stderr)
            exit(1)
        }

        if args.contains("--self-test") {
            let assetsDir = ProcessInfo.processInfo.environment["KASTOR_E2E_ASSETS_DIR"]
            let result = DriverSelfTest.run(assetsDir: assetsDir)
            emitResult(result, encoder: encoder)
            exit(result.status == .PASS ? 0 : 1)
        }

        var selectedIDs: [String] = []
        if args.contains("--all") {
            selectedIDs = allCases.map { $0.id }
        } else if let idx = args.firstIndex(of: "--case"), idx + 1 < args.count {
            selectedIDs = [args[idx + 1]]
        } else if let idx = args.firstIndex(of: "--batch"), idx + 1 < args.count {
            selectedIDs = args[idx + 1]
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            fputs("Usage: kastor_driver [--list | --self-test | --case <id> | --batch <id1,id2,...> | --all]\n", stderr)
            exit(2)
        }

        DriverAppRuntime.ensureInitialized()

        let byID = Dictionary(uniqueKeysWithValues: allCases.map { ($0.id, $0) })
        var allPassed = true

        for caseID in selectedIDs {
            guard let spec = byID[caseID] else {
                let res = DriverCaseResult.error(id: caseID, message: "Unknown Swift driver case id: \(caseID)")
                emitResult(res, encoder: encoder)
                allPassed = false
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            let env: IsolatedTestEnvironment
            do {
                env = try IsolatedTestEnvironment()
            } catch {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                emitResult(
                    DriverCaseResult.error(id: caseID, message: "Failed to initialize isolated test env: \(error)", durationMs: elapsed),
                    encoder: encoder
                )
                allPassed = false
                continue
            }
            defer { env.cleanup() }

            do {
                var result = try spec.run(env)
                if result.durationMs == 0 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                    result = DriverCaseResult(
                        id: result.id,
                        status: result.status,
                        message: result.message,
                        durationMs: elapsed,
                        metrics: result.metrics
                    )
                }
                emitResult(result, encoder: encoder)
                if result.status != .PASS {
                    allPassed = false
                }
            } catch let failure as DriverFailure {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                emitResult(
                    DriverCaseResult.fail(id: caseID, message: failure.message, durationMs: elapsed),
                    encoder: encoder
                )
                allPassed = false
            } catch {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                emitResult(
                    DriverCaseResult.error(id: caseID, message: "Unhandled error: \(error)", durationMs: elapsed),
                    encoder: encoder
                )
                allPassed = false
            }
        }

        exit(allPassed ? 0 : 1)
    }

    private static func emitResult(_ result: DriverCaseResult, encoder: JSONEncoder) {
        if let data = try? encoder.encode(result),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        } else {
            print("{\"id\":\"\(result.id)\",\"status\":\"ERROR\",\"message\":\"JSON encoding failure\",\"duration_ms\":0,\"metrics\":{}}")
        }
    }
}
