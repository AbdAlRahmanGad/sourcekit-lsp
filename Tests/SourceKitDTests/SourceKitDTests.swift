//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import ISDBTestSupport
import ISDBTibs
import LSPTestSupport
import SKCore
import SKSupport
import SourceKitD
import TSCBasic
import XCTest
import LanguageServerProtocol
import SKTestSupport

import enum PackageLoading.Platform
import class TSCBasic.Process

final class SourceKitDTests: XCTestCase {
  static var sourcekitdPath: AbsolutePath! = nil
  static var sdkpath: String? = nil

  override class func setUp() {
    sourcekitdPath = ToolchainRegistry.shared.default!.sourcekitd!
    guard case .darwin? = Platform.current else { return }
    sdkpath = try? Process.checkNonZeroExit(args: "/usr/bin/xcrun", "--show-sdk-path", "--sdk", "macosx")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testMultipleNotificationHandlers() async throws {
    let sourcekitd = try SourceKitDImpl.getOrCreate(dylibPath: SourceKitDTests.sourcekitdPath)
    let keys = sourcekitd.keys
    let path = DocumentURI.for(.swift).pseudoPath

    let isExpectedNotification = { (response: SKDResponse) -> Bool in
      if let notification: sourcekitd_uid_t = response.value?[keys.notification],
        let name: String = response.value?[keys.name]
      {
        return name == path && notification == sourcekitd.values.notification_documentupdate
      }
      return false
    }

    let expectation1 = expectation(description: "handler 1")
    let handler1 = ClosureNotificationHandler { response in
      if isExpectedNotification(response) {
        expectation1.fulfill()
      }
    }
    // SourceKitDImpl weakly references handlers
    defer {
      _fixLifetime(handler1)
    }
    sourcekitd.addNotificationHandler(handler1)

    let expectation2 = expectation(description: "handler 2")
    let handler2 = ClosureNotificationHandler { response in
      if isExpectedNotification(response) {
        expectation2.fulfill()
      }
    }
    // SourceKitDImpl weakly references handlers
    defer {
      _fixLifetime(handler2)
    }
    sourcekitd.addNotificationHandler(handler2)

    let req = SKDRequestDictionary(sourcekitd: sourcekitd)
    req[keys.request] = sourcekitd.requests.editor_open
    req[keys.name] = path
    req[keys.sourcetext] = """
      func foo() {}
      """
    let args = SKDRequestArray(sourcekitd: sourcekitd)
    if let sdkpath = SourceKitDTests.sdkpath {
      args.append("-sdk")
      args.append(sdkpath)
    }
    args.append(path)
    req[keys.compilerargs] = args

    _ = try await sourcekitd.send(req, fileContents: nil)

    try await fulfillmentOfOrThrow([expectation1, expectation2])

    let close = SKDRequestDictionary(sourcekitd: sourcekitd)
    close[keys.request] = sourcekitd.requests.editor_close
    close[keys.name] = path
    _ = try await sourcekitd.send(close, fileContents: nil)
  }
}

private class ClosureNotificationHandler: SKDNotificationHandler {
  let f: (SKDResponse) -> Void

  init(_ f: @escaping (SKDResponse) -> Void) {
    self.f = f
  }

  func notification(_ response: SKDResponse) {
    f(response)
  }
}
