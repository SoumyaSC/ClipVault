import Foundation
@testable import ClipVaultCore


// MARK: - Minimal XCTest-compatible harness (no Xcode required)
//
// The Command Line Tools toolchain does not ship the XCTest framework, so this
// target ships a tiny assertion layer with the same call signatures used by the
// test files, plus an explicit runner in main.swift.

final class TestContext {
    static var failures: [String] = []
    static var currentTest = ""
    static var passed = 0
    static var failed = 0

    static func recordFailure(_ message: String, file: StaticString, line: UInt) {
        failures.append("\(currentTest): \(message) (\(file):\(line))")
        print("  ✗ \(currentTest): \(message)")
    }
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    TestContext.recordFailure(message.isEmpty ? " XCTFail" : message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    if a != b {
        TestContext.recordFailure("\(message.isEmpty ? "" : message + " — ")expected \(String(describing: b)), got \(String(describing: a))", file: file, line: line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    if a == b {
        TestContext.recordFailure("\(message.isEmpty ? "" : message + " — ")values unexpectedly equal: \(String(describing: a))", file: file, line: line)
    }
}

func XCTAssertTrue(_ cond: Bool, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    if !cond {
        TestContext.recordFailure(message.isEmpty ? "expected true" : message, file: file, line: line)
    }
}

func XCTAssertFalse(_ cond: Bool, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    if cond {
        TestContext.recordFailure(message.isEmpty ? "expected false" : message, file: file, line: line)
    }
}

func XCTAssertNil<T>(_ value: T?, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    if value != nil {
        TestContext.recordFailure(message.isEmpty ? "expected nil, got \(String(describing: value))" : message, file: file, line: line)
    }
}

func XCTAssertNotNil<T>(_ value: T?, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    if value == nil {
        TestContext.recordFailure(message.isEmpty ? "expected non-nil" : message, file: file, line: line)
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, _ message: String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    if a > b {
        TestContext.recordFailure("\(message.isEmpty ? "" : message + " — ")\(a) not <= \(b)", file: file, line: line)
    }
}

/// Base class standing in for XCTestCase; hooks are no-ops unless overridden.
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

/// Runs one test body with harness bookkeeping.
func runTest(_ name: String, _ body: () throws -> Void) {
    TestContext.currentTest = name
    do {
        try body()
    } catch {
        TestContext.recordFailure("threw: \(error)", file: #filePath, line: #line)
    }
    if TestContext.failures.isEmpty || !TestContext.failures.contains(where: { $0.hasPrefix(name) }) {
        TestContext.passed += 1
        print("  ✓ \(name)")
    } else {
        TestContext.failed += 1
    }
}

// MARK: - Scratch settings storage

/// In-memory stand-in for `UserDefaults`, so a test run never writes a plist
/// into ~/Library/Preferences (and never inherits state from a previous run).
final class MemoryDefaults: SettingsDefaults {
    private var storage: [String: Any] = [:]

    func object(forKey key: String) -> Any? { storage[key] }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
}
