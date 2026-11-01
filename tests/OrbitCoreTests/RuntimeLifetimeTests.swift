import Foundation
import XCTest

@testable import OrbitCore

final class RuntimeLifetimeTests: XCTestCase {
  private final class Probe: NSObject {}

  func testCommandBoundaryReleasesTemporaryObjectiveCObjects() {
    weak var observed: Probe?
    withOrbitRuntime(OrbitRuntime()) {
      let value = Probe()
      observed = value
      _ = Unmanaged.passRetained(value).autorelease()
    }
    XCTAssertNil(observed, "Temporary Objective-C objects must not accumulate until the host run loop returns")
  }

  func testReturnedObjectsSurviveTheCommandBoundary() {
    weak var observed: Probe?
    let returned = withOrbitRuntime(OrbitRuntime()) {
      let value = Probe()
      observed = value
      _ = Unmanaged.passRetained(value).autorelease()
      return value
    }
    XCTAssertTrue(observed === returned)
  }

  func testCancellationReleasesTemporariesAndRestoresOuterRuntime() throws {
    weak var observed: Probe?
    try withOrbitRuntime(OrbitRuntime(clock: { "outer" })) {
      XCTAssertThrowsError(try withOrbitRuntime(OrbitRuntime(clock: { "inner" })) {
        let value = Probe()
        observed = value
        _ = Unmanaged.passRetained(value).autorelease()
        throw CancellationError()
      }) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertNil(observed)
      XCTAssertEqual(now(), "outer")
    }
  }
}
