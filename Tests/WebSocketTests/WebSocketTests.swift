import XCTest
@testable import WebSocket

class WebSocketTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssertEqual(WebSocket().text, "Hello, World!")
    }


    static var allTests : [(String, (WebSocketTests) -> () throws -> Void)] {
        return [
            ("testExample", testExample),
        ]
    }
}
