import XCTest
@testable import HTTrailCore

final class BonjourPublishStateTests: XCTestCase {
    func testPublishEmitsPublishingThenPublished() {
        let adv = BonjourAdvertiser()
        let publishing = expectation(description: "publishing")
        let published = expectation(description: "published")
        var sawPublishing = false
        adv.onState = { state in
            switch state {
            case .publishing: if !sawPublishing { sawPublishing = true; publishing.fulfill() }
            case .published: published.fulfill()
            case .failed: break
            }
        }
        adv.start(name: "HTTrailTest-\(UUID().uuidString.prefix(6))", port: 9099, caPort: 0, caFP: "", pairPort: 9098)
        wait(for: [publishing, published], timeout: 10)
        adv.stop()
    }
}
