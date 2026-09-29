// Run the same assertions on machines with Command Line Tools but no XCTest.
import Foundation

var checkFailures: [String] = []
func failure(_ message: String, file: StaticString, line: UInt) { checkFailures.append("\(file):\(line): \(message)") }
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { failure("Expected \(a) to equal \(b)",file:file,line:line) } } catch { failure(error.localizedDescription,file:file,line:line) }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() == rhs() { failure("Expected different values",file:file,line:line) } } catch { failure(error.localizedDescription,file:file,line:line) }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { failure("Expected true",file:file,line:line) } } catch { failure(error.localizedDescription,file:file,line:line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { failure("Expected false",file:file,line:line) } } catch { failure(error.localizedDescription,file:file,line:line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { failure("Expected nil",file:file,line:line) } } catch { failure(error.localizedDescription,file:file,line:line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); failure("Expected an error",file:file,line:line) } catch { handler(error) }
}
