//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import IndexStoreDB
import LSPLogging
import LanguageServerProtocol
import SKSupport
import SourceKitD

// MARK: - Helper types

/// A parsed representation of a name that may be disambiguated by its argument labels.
///
/// ### Examples
///  - `foo(a:b:)`
///  - `foo(_:b:)`
///  - `foo` if no argument labels are specified, eg. for a variable.
fileprivate struct CompoundDeclName {
  /// The parameter of a compound decl name, which can either be the parameter's name or `_` to indicate that the
  /// parameter is unnamed.
  enum Parameter: Equatable {
    case named(String)
    case wildcard

    var stringOrWildcard: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return "_"
      }
    }

    var stringOrEmpty: String {
      switch self {
      case .named(let str): return str
      case .wildcard: return ""
      }
    }
  }

  let baseName: String
  let parameters: [Parameter]

  /// Parse a compound decl name into its base names and parameters.
  init(_ compoundDeclName: String) {
    guard let openParen = compoundDeclName.firstIndex(of: "(") else {
      // We don't have a compound name. Everything is the base name
      self.baseName = compoundDeclName
      self.parameters = []
      return
    }
    self.baseName = String(compoundDeclName[..<openParen])
    let closeParen = compoundDeclName.firstIndex(of: ")") ?? compoundDeclName.endIndex
    let parametersText = compoundDeclName[compoundDeclName.index(after: openParen)..<closeParen]
    // Split by `:` to get the parameter names. Drop the last element so that we don't have a trailing empty element
    // after the last `:`.
    let parameterStrings = parametersText.split(separator: ":", omittingEmptySubsequences: false).dropLast()
    parameters = parameterStrings.map {
      switch $0 {
      case "", "_": return .wildcard
      default: return .named(String($0))
      }
    }
  }
}

/// The kind of range that a `SyntacticRenamePiece` can be.
fileprivate enum SyntacticRenamePieceKind {
  /// The base name of a function or the name of a variable, which can be renamed.
  ///
  /// ### Examples
  /// - `foo` in `func foo(a b: Int)`.
  /// - `foo` in `let foo = 1`
  case baseName

  /// The base name of a function-like declaration that cannot be renamed
  ///
  /// ### Examples
  /// - `init` in `init(a: Int)`
  /// - `subscript` in `subscript(a: Int) -> Int`
  case keywordBaseName

  /// The internal parameter name (aka. second name) inside a function declaration
  ///
  /// ### Examples
  /// - ` b` in `func foo(a b: Int)`
  case parameterName

  /// Same as `parameterName` but cannot be removed if it is the same as the parameter's first name. This only happens
  /// for subscripts where parameters are unnamed by default unless they have both a first and second name.
  ///
  /// ### Examples
  /// The second ` a` in `subscript(a a: Int)`
  case noncollapsibleParameterName

  /// The external argument label of a function parameter
  ///
  /// ### Examples
  /// - `a` in `func foo(a b: Int)`
  /// - `a` in `func foo(a: Int)`
  case declArgumentLabel

  /// The argument label inside a call.
  ///
  /// ### Examples
  /// - `a` in `foo(a: 1)`
  case callArgumentLabel

  /// The colon after an argument label inside a call. This is reported so it can be removed if the parameter becomes
  /// unnamed.
  ///
  /// ### Examples
  /// - `: ` in `foo(a: 1)`
  case callArgumentColon

  /// An empty range that point to the position before an unnamed argument. This is used to insert the argument label
  /// if an unnamed parameter becomes named.
  ///
  /// ### Examples
  /// - An empty range before `1` in `foo(1)`, which could expand to `foo(a: 1)`
  case callArgumentCombined

  /// The argument label in a compound decl name.
  ///
  /// ### Examples
  /// - `a` in `foo(a:)`
  case selectorArgumentLabel

  init?(_ uid: sourcekitd_uid_t, keys: sourcekitd_keys) {
    switch uid {
    case keys.renameRangeBase: self = .baseName
    case keys.renameRangeCallArgColon: self = .callArgumentColon
    case keys.renameRangeCallArgCombined: self = .callArgumentCombined
    case keys.renameRangeCallArgLabel: self = .callArgumentLabel
    case keys.renameRangeDeclArgLabel: self = .declArgumentLabel
    case keys.renameRangeKeywordBase: self = .keywordBaseName
    case keys.renameRangeNoncollapsibleParam: self = .noncollapsibleParameterName
    case keys.renameRangeParam: self = .parameterName
    case keys.renameRangeSelectorArgLabel: self = .selectorArgumentLabel
    default: return nil
    }
  }
}

/// A single “piece” that is used for renaming a compound function name.
///
/// See `SyntacticRenamePieceKind` for the different rename pieces that exist.
///
/// ### Example
/// `foo(x: 1)` is represented by three pieces
/// - The base name `foo`
/// - The parameter name `x`
/// - The call argument colon `: `.
fileprivate struct SyntacticRenamePiece {
  /// The range that represents this piece of the name
  let range: Range<Position>

  /// The kind of the rename piece.
  let kind: SyntacticRenamePieceKind

  /// If this piece belongs to a parameter, the index of that parameter (zero-based) or `nil` if this is the base name
  /// piece.
  let parameterIndex: Int?

  /// Create a `SyntacticRenamePiece` from a `sourcekitd` response.
  init?(_ dict: SKDResponseDictionary, in snapshot: DocumentSnapshot, keys: sourcekitd_keys) {
    guard let line: Int = dict[keys.line],
      let column: Int = dict[keys.column],
      let endLine: Int = dict[keys.endline],
      let endColumn: Int = dict[keys.endcolumn],
      let kind: sourcekitd_uid_t = dict[keys.kind]
    else {
      return nil
    }
    guard
      let start = snapshot.positionOf(zeroBasedLine: line - 1, utf8Column: column - 1),
      let end = snapshot.positionOf(zeroBasedLine: endLine - 1, utf8Column: endColumn - 1)
    else {
      return nil
    }
    guard let kind = SyntacticRenamePieceKind(kind, keys: keys) else {
      return nil
    }

    self.range = start..<end
    self.kind = kind
    self.parameterIndex = dict[keys.argindex] as Int?
  }
}

/// The context in which the location to be renamed occurred.
fileprivate enum SyntacticRenameNameContext {
  /// No syntactic rename ranges for the rename location could be found.
  case unmatched

  /// A name could be found at a requested rename location but the name did not match the specified old name.
  case mismatch

  /// The matched ranges are in active source code (ie. source code that is not an inactive `#if` range).
  case activeCode

  /// The matched ranges are in an inactive `#if` region of the source code.
  case inactiveCode

  /// The matched ranges occur inside a string literal.
  case string

  /// The matched ranges occur inside a `#selector` directive.
  case selector

  /// The matched ranges are within a comment.
  case comment

  init?(_ uid: sourcekitd_uid_t, keys: sourcekitd_keys) {
    switch uid {
    case keys.sourceEditKindActive: self = .activeCode
    case keys.sourceEditKindComment: self = .comment
    case keys.sourceEditKindInactive: self = .inactiveCode
    case keys.sourceEditKindMismatch: self = .mismatch
    case keys.sourceEditKindSelector: self = .selector
    case keys.sourceEditKindString: self = .string
    case keys.sourceEditKindUnknown: self = .unmatched
    default: return nil
    }
  }
}

/// A set of ranges that, combined, represent which edits need to be made to rename a possibly compound name.
///
/// See `SyntacticRenamePiece` for more details.
fileprivate struct SyntacticRenameName {
  let pieces: [SyntacticRenamePiece]
  let category: SyntacticRenameNameContext

  init?(_ dict: SKDResponseDictionary, in snapshot: DocumentSnapshot, keys: sourcekitd_keys) {
    guard let ranges: SKDResponseArray = dict[keys.ranges] else {
      return nil
    }
    self.pieces = ranges.compactMap { SyntacticRenamePiece($0, in: snapshot, keys: keys) }
    guard let categoryUid: sourcekitd_uid_t = dict[keys.category],
      let category = SyntacticRenameNameContext(categoryUid, keys: keys)
    else {
      return nil
    }
    self.category = category
  }
}

private extension LineTable {
  subscript(range: Range<Position>) -> Substring? {
    guard let start = self.stringIndexOf(line: range.lowerBound.line, utf16Column: range.lowerBound.utf16index),
      let end = self.stringIndexOf(line: range.upperBound.line, utf16Column: range.upperBound.utf16index)
    else {
      return nil
    }
    return self.content[start..<end]
  }
}

private extension DocumentSnapshot {
  init?(_ uri: DocumentURI, language: Language) throws {
    guard let url = uri.fileURL else {
      return nil
    }
    let contents = try String(contentsOf: url)
    self.init(uri: DocumentURI(url), language: language, version: 0, lineTable: LineTable(contents))
  }

  func position(of renameLocation: RenameLocation) -> Position? {
    return positionOf(zeroBasedLine: renameLocation.line - 1, utf8Column: renameLocation.utf8Column - 1)
  }
}

private extension RenameLocation.Usage {
  init(roles: SymbolRole) {
    if roles.contains(.definition) || roles.contains(.declaration) {
      self = .definition
    } else if roles.contains(.call) {
      self = .call
    } else {
      self = .reference
    }
  }
}

// MARK: - Name translation

extension SwiftLanguageServer {
  enum NameTranslationError: Error, CustomStringConvertible {
    case cannotComputeOffset(Position)
    case malformedSwiftToClangTranslateNameResponse(SKDResponseDictionary)
    case malformedClangToSwiftTranslateNameResponse(SKDResponseDictionary)

    var description: String {
      switch self {
      case .cannotComputeOffset(let position):
        return "Failed to determine UTF-8 offset of \(position)"
      case .malformedSwiftToClangTranslateNameResponse(let response):
        return """
          Malformed response for Swift to Clang name translation

          \(response.description)
          """
      case .malformedClangToSwiftTranslateNameResponse(let response):
        return """
          Malformed response for Clang to Swift name translation

          \(response.description)
          """
      }
    }
  }

  /// Translate a Swift name to the corresponding C/C++/ObjectiveC name.
  ///
  /// This invokes the clang importer to perform the name translation.
  ///
  /// - Parameters:
  ///   - position: The position at which the Swift name is defined
  ///   - uri: The URI of the document in which the Swift name is defined
  ///   - name: The Swift name of the symbol
  fileprivate func translateSwiftNameToClang(
    at position: Position,
    in uri: DocumentURI,
    name: CompoundDeclName
  ) async throws -> String {
    let snapshot = try documentManager.latestSnapshot(uri)

    guard let offset = snapshot.utf8Offset(of: position) else {
      throw NameTranslationError.cannotComputeOffset(position)
    }

    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourcefile: snapshot.uri.pseudoPath,
      keys.compilerargs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDValue]?,
      keys.offset: offset,
      keys.namekind: sourcekitd.values.namekindSwift,
      keys.baseName: name.baseName,
      keys.argNames: sourcekitd.array(name.parameters.map { $0.stringOrWildcard }),
    ])

    let response = try await sourcekitd.send(req, fileContents: snapshot.text)

    guard let isZeroArgSelector: Int = response[keys.isZeroArgSelector],
      let selectorPieces: SKDResponseArray = response[keys.selectorPieces]
    else {
      throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
    }
    return
      try selectorPieces
      .map { (dict: SKDResponseDictionary) -> String in
        guard var name: String = dict[keys.name] else {
          throw NameTranslationError.malformedSwiftToClangTranslateNameResponse(response)
        }
        if isZeroArgSelector == 0 {
          // Selector pieces in multi-arg selectors end with ":"
          name.append(":")
        }
        return name
      }.joined()
  }

  /// Translates a C/C++/Objective-C symbol name to Swift.
  ///
  /// This requires the position at which the the symbol is referenced in Swift so sourcekitd can determine the
  /// clang declaration that is being renamed and check if that declaration has a `SWIFT_NAME`. If it does, this
  /// `SWIFT_NAME` is used as the name translation result instead of invoking the clang importer rename rules.
  ///
  /// - Parameters:
  ///   - position: A position at which this symbol is referenced from Swift.
  ///   - snapshot: The snapshot containing the `position` that points to a usage of the clang symbol.
  ///   - isObjectiveCSelector: Whether the name is an Objective-C selector. Cannot be inferred from the name because
  ///     a name without `:` can also be a zero-arg Objective-C selector. For such names sourcekitd needs to know
  ///     whether it is translating a selector to apply the correct renaming rule.
  ///   - name: The clang symbol name.
  /// - Returns:
  fileprivate func translateClangNameToSwift(
    at position: Position,
    in snapshot: DocumentSnapshot,
    isObjectiveCSelector: Bool,
    name: String
  ) async throws -> String {
    guard let offset = snapshot.utf8Offset(of: position) else {
      throw NameTranslationError.cannotComputeOffset(position)
    }
    let req = sourcekitd.dictionary([
      keys.request: sourcekitd.requests.nameTranslation,
      keys.sourcefile: snapshot.uri.pseudoPath,
      keys.compilerargs: await self.buildSettings(for: snapshot.uri)?.compilerArgs as [SKDValue]?,
      keys.offset: offset,
      keys.namekind: sourcekitd.values.namekindObjC,
    ])

    if isObjectiveCSelector {
      // Split the name into selector pieces, keeping the ':'.
      let selectorPieces = name.split(separator: ":").map { String($0 + ":") }
      req.set(keys.selectorPieces, to: sourcekitd.array(selectorPieces))
    } else {
      req.set(keys.baseName, to: name)
    }

    let response = try await sourcekitd.send(req, fileContents: snapshot.text)

    guard let baseName: String = response[keys.baseName] else {
      throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
    }
    let argNamesArray: SKDResponseArray? = response[keys.argNames]
    let argNames = try argNamesArray?.map { (dict: SKDResponseDictionary) -> String in
      guard var name: String = dict[keys.name] else {
        throw NameTranslationError.malformedClangToSwiftTranslateNameResponse(response)
      }
      if name.isEmpty {
        // Empty argument names are represented by `_` in Swift.
        name = "_"
      }
      return name + ":"
    }
    var result = baseName
    if let argNames, !argNames.isEmpty {
      result += "(" + argNames.joined() + ")"
    }
    return result
  }
}

/// A symbol name that can be translated between Swift and clang.
///
/// All properties refer to the definition symbol. For example, an Objective-C method named `performAction:with:` that
/// is imported to Swift as `perform(action:with:)` will always have its definition in an Objective-C source file and
/// the definition name will always be `performAction:with:`, even if rename is invoked from Swift.
public actor TranslatableName {
  /// The symbol's name as it is spelled in the language it is defined in.
  let definitionName: String

  /// The document in which the symbol is defined.
  private let definitionDocumentUri: DocumentURI

  /// The position in `definitionDocumentURI` at which the symbol is defined.
  private let definitionPosition: Position

  /// The language service that handles the document in which the native symbol is defined.
  private let definitionLanguageService: ToolchainLanguageServer

  /// Whether the symbol is an Objective-C selector. This influences clang to Swift name translation.
  private let isObjectiveCSelector: Bool

  /// If the symbol is a Swift symbol, the task that translates the symbol to clang after the swift name is requested
  /// for the first time using `clangName`.
  ///
  /// This allows us to cache the translated name.
  private var swiftToClangTranslationTask: Task<String, Error>?

  /// If the symbol is a clang symbol, the task that translates the symbol to Swift after the swift name is requested
  /// for the first time using `swiftName`.
  ///
  /// This allows us to cache the translated name.
  private var clangToSwiftTranslationTask: Task<String, Error>?

  init(
    definitionName: String,
    definitionDocumentUri: DocumentURI,
    definitionPosition: Position,
    definitionLanguageService: any ToolchainLanguageServer,
    isObjectiveCSelector: Bool
  ) {
    self.definitionName = definitionName
    self.definitionDocumentUri = definitionDocumentUri
    self.definitionPosition = definitionPosition
    self.definitionLanguageService = definitionLanguageService
    self.isObjectiveCSelector = isObjectiveCSelector
  }

  nonisolated func with(name: String) -> TranslatableName {
    return TranslatableName(
      definitionName: name,
      definitionDocumentUri: self.definitionDocumentUri,
      definitionPosition: self.definitionPosition,
      definitionLanguageService: self.definitionLanguageService,
      isObjectiveCSelector: self.isObjectiveCSelector
    )
  }

  /// Get the name of the symbol as it should be used to perform a rename in clang files.
  ///
  /// For example, this performs Swift function to Objective-C selector translation or strips parentheses for Swift
  /// functions imported into C.
  func clangName() async throws -> String {
    switch definitionLanguageService {
    case let swiftLanguageService as SwiftLanguageServer:
      if swiftToClangTranslationTask == nil {
        swiftToClangTranslationTask = Task {
          try await swiftLanguageService.translateSwiftNameToClang(
            at: definitionPosition,
            in: definitionDocumentUri,
            name: CompoundDeclName(definitionName)
          )
        }
      }
      return try await swiftToClangTranslationTask!.value
    case is ClangLanguageServerShim:
      return definitionName
    default:
      throw ResponseError.unknown("Cannot rename symbol because it is defined in an unknown language")
    }
  }

  /// Get the name of the symbol as it should be used to perform a rename in Swift files.
  ///
  /// This runs the clang importer to translates Objective-C selectors to Swift functions.
  ///
  /// - Note: The symbol translation from clang to Swift requires a Swift location at which the clang symbol is
  ///   (probably so that sourcekitd can access the necessary AST context and get the clang importer to translate the
  ///   name). But the output does not actually matter on the specific position and URI. We can thus cache the result.
  ///   Ideally, sourcekitd wouldn't need a position and URI to translate a clang name to Swift.
  func swiftName(
    at position: Position,
    in snapshot: DocumentSnapshot,
    languageService: SwiftLanguageServer
  ) async throws -> String {
    switch definitionLanguageService {
    case is SwiftLanguageServer:
      return definitionName
    case is ClangLanguageServerShim:
      if clangToSwiftTranslationTask == nil {
        clangToSwiftTranslationTask = Task {
          try await languageService.translateClangNameToSwift(
            at: position,
            in: snapshot,
            isObjectiveCSelector: isObjectiveCSelector,
            name: definitionName
          )
        }
      }
      return try await clangToSwiftTranslationTask!.value
    default:
      throw ResponseError.unknown("Cannot rename symbol because it is defined in an unknown language")
    }
  }
}

// MARK: - SourceKitServer

extension SourceKitServer {
  private func getTranslatableName(
    forUsr usr: String,
    workspace: Workspace,
    index: IndexStoreDB
  ) async throws -> (name: TranslatableName, language: Language)? {
    guard let definitionSymbol = index.occurrences(ofUSR: usr, roles: [.definition]).only else {
      logger.error("Multiple or no definitions for \(usr) found")
      return nil
    }
    let definitionLanguage: Language =
      switch definitionSymbol.symbol.language {
      case .c: .c
      case .cxx: .cpp
      case .objc: .objective_c
      case .swift: .swift
      }
    let definitionDocumentUri = DocumentURI(URL(fileURLWithPath: definitionSymbol.location.path))

    let isObjectiveCSelector =
      definitionLanguage == .objective_c
      && (definitionSymbol.symbol.kind == .instanceMethod || definitionSymbol.symbol.kind == .classMethod)

    guard
      let nativeLanguageService = await self.languageService(
        for: definitionDocumentUri,
        definitionLanguage,
        in: workspace
      )
    else {
      logger.fault("Failed to get language service for the document defining \(usr)")
      return nil
    }

    guard
      let definitionDocumentSnapshot = (try? self.documentManager.latestSnapshot(definitionDocumentUri))
        ?? (try? DocumentSnapshot(definitionDocumentUri, language: definitionLanguage))
    else {
      logger.fault("Failed to get document snapshot for \(definitionDocumentUri)")
      return nil
    }

    guard
      let definitionPosition = definitionDocumentSnapshot.positionOf(
        zeroBasedLine: definitionSymbol.location.line - 1,
        utf8Column: definitionSymbol.location.utf8Column - 1
      )
    else {
      logger.fault(
        "Failed to convert definition position to UTF-16 column \(definitionDocumentUri.forLogging):\(definitionSymbol.location.line):\(definitionSymbol.location.utf8Column)"
      )
      return nil
    }
    let definitionName = definitionSymbol.symbol.name

    let name = TranslatableName(
      definitionName: definitionName,
      definitionDocumentUri: definitionDocumentUri,
      definitionPosition: definitionPosition,
      definitionLanguageService: nativeLanguageService,
      isObjectiveCSelector: isObjectiveCSelector
    )
    return (name, definitionLanguage)
  }

  func rename(_ request: RenameRequest) async throws -> WorkspaceEdit? {
    let uri = request.textDocument.uri
    let snapshot = try documentManager.latestSnapshot(uri)

    guard let workspace = await workspaceForDocument(uri: uri) else {
      throw ResponseError.workspaceNotOpen(uri)
    }
    guard let primaryFileLanguageService = workspace.documentService[uri] else {
      return nil
    }

    // Determine the local edits and the USR to rename
    let renameResult = try await primaryFileLanguageService.rename(request)

    guard let usr = renameResult.usr, let index = workspace.index else {
      // We don't have enough information to perform a cross-file rename.
      return renameResult.edits
    }

    guard
      let (oldTranslatableName, nativeLanguage) = try await getTranslatableName(
        forUsr: usr,
        workspace: workspace,
        index: index
      )
    else {
      // We failed to get the translatable name, so we can't to global rename.
      // Do local rename within the current file instead as fallback.
      return renameResult.edits
    }

    var changes: [DocumentURI: [TextEdit]] = [:]
    if nativeLanguage == snapshot.language {
      // If this is not a cross-language rename, we can use the local edits returned by
      // the language service's rename function.
      // If this is cross-language rename, that's not possible because the user would eg.
      // enter a new clang name, which needs to be translated to the Swift name before
      // changing the current file.
      changes = renameResult.edits.changes ?? [:]
    }

    let newTranslatableName = oldTranslatableName.with(name: request.newName)

    // If we have a USR + old name, perform an index lookup to find workspace-wide symbols to rename.
    // First, group all occurrences of that USR by the files they occur in.
    var locationsByFile: [URL: [RenameLocation]] = [:]
    let occurrences = index.occurrences(ofUSR: usr, roles: [.declaration, .definition, .reference])
    for occurrence in occurrences {
      let url = URL(fileURLWithPath: occurrence.location.path)
      let renameLocation = RenameLocation(
        line: occurrence.location.line,
        utf8Column: occurrence.location.utf8Column,
        usage: RenameLocation.Usage(roles: occurrence.roles)
      )
      locationsByFile[url, default: []].append(renameLocation)
    }

    // Now, call `editsToRename(locations:in:oldName:newName:)` on the language service to convert these ranges into
    // edits.
    let urisAndEdits =
      await locationsByFile
      .filter { changes[DocumentURI($0.key)] == nil }
      .concurrentMap { (url: URL, renameLocations: [RenameLocation]) -> (DocumentURI, [TextEdit])? in
        let uri = DocumentURI(url)
        let language: Language
        switch index.symbolProvider(for: url.path) {
        case .clang:
          // Technically, we still don't know the language of the source file but defaulting to C is sufficient to
          // ensure we get the clang toolchain language server, which is all we care about.
          language = .c
        case .swift:
          language = .swift
        case nil:
          logger.error("Failed to determine symbol provider for \(uri.forLogging)")
          return nil
        }
        // Create a document snapshot to operate on. If the document is open, load it from the document manager,
        // otherwise conjure one from the file on disk. We need the file in memory to perform UTF-8 to UTF-16 column
        // conversions.
        guard
          let snapshot = (try? self.documentManager.latestSnapshot(uri))
            ?? (try? DocumentSnapshot(uri, language: language))
        else {
          logger.error("Failed to get document snapshot for \(uri.forLogging)")
          return nil
        }
        do {
          guard let languageService = await self.languageService(for: uri, language, in: workspace) else {
            return nil
          }
          let edits = try await languageService.editsToRename(
            locations: renameLocations,
            in: snapshot,
            oldName: oldTranslatableName,
            newName: newTranslatableName
          )
          return (uri, edits)
        } catch {
          logger.error("Failed to get edits for \(uri.forLogging): \(error.forLogging)")
          return nil
        }
      }.compactMap { $0 }
    for (uri, editsForUri) in urisAndEdits {
      precondition(
        changes[uri] == nil,
        "We should have only computed edits for URIs that didn't have edits from the initial rename request"
      )
      if !editsForUri.isEmpty {
        changes[uri] = editsForUri
      }
    }
    var edits = renameResult.edits
    edits.changes = changes
    return edits
  }

  func prepareRename(
    _ request: PrepareRenameRequest,
    workspace: Workspace,
    languageService: ToolchainLanguageServer
  ) async throws -> PrepareRenameResponse? {
    guard var prepareRenameResult = try await languageService.prepareRename(request) else {
      return nil
    }

    let symbolInfo = try await languageService.symbolInfo(
      SymbolInfoRequest(textDocument: request.textDocument, position: request.position)
    )

    guard
      let index = workspace.index,
      let usr = symbolInfo.only?.usr,
      let oldName = try await self.getTranslatableName(forUsr: usr, workspace: workspace, index: index)?.name
    else {
      return prepareRenameResult
    }

    // Get the name of the symbol's definition, if possible.
    // This is necessary for cross-language rename. Eg. when renaming an Objective-C method from Swift,
    // the user still needs to enter the new Objective-C name.
    prepareRenameResult.placeholder = oldName.definitionName
    return prepareRenameResult
  }
}

// MARK: - Swift

extension SwiftLanguageServer {
  /// From a list of rename locations compute the list of `SyntacticRenameName`s that define which ranges need to be
  /// edited to rename a compound decl name.
  ///
  /// - Parameters:
  ///   - renameLocations: The locations to rename
  ///   - oldName: The compound decl name that the declaration had before the rename. Used to verify that the rename
  ///     locations match that name. Eg. `myFunc(argLabel:otherLabel:)` or `myVar`
  ///   - snapshot: A `DocumentSnapshot` containing the contents of the file for which to compute the rename ranges.
  private func getSyntacticRenameRanges(
    renameLocations: [RenameLocation],
    oldName: String,
    in snapshot: DocumentSnapshot
  ) async throws -> [SyntacticRenameName] {
    let locations = sourcekitd.array(
      renameLocations.map { renameLocation in
        let location = sourcekitd.dictionary([
          keys.line: renameLocation.line,
          keys.column: renameLocation.utf8Column,
          keys.nameType: renameLocation.usage.uid(keys: keys),
        ])
        return sourcekitd.dictionary([
          keys.locations: [location],
          keys.name: oldName,
        ])
      }
    )

    let skreq = sourcekitd.dictionary([
      keys.request: requests.find_syntactic_rename_ranges,
      keys.sourcefile: snapshot.uri.pseudoPath,
      // find-syntactic-rename-ranges is a syntactic sourcekitd request that doesn't use the in-memory file snapshot.
      // We need to send the source text again.
      keys.sourcetext: snapshot.text,
      keys.renamelocations: locations,
    ])

    let syntacticRenameRangesResponse = try await sourcekitd.send(skreq, fileContents: snapshot.text)
    guard let categorizedRanges: SKDResponseArray = syntacticRenameRangesResponse[keys.categorizedranges] else {
      throw ResponseError.internalError("sourcekitd did not return categorized ranges")
    }

    return categorizedRanges.compactMap { SyntacticRenameName($0, in: snapshot, keys: keys) }
  }

  public func rename(_ request: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let relatedIdentifiersResponse = try await self.relatedIdentifiers(
      at: request.position,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard let oldName = relatedIdentifiersResponse.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }

    try Task.checkCancellation()

    let renameLocations = relatedIdentifiersResponse.relatedIdentifiers.compactMap {
      (relatedIdentifier) -> RenameLocation? in
      let position = relatedIdentifier.range.lowerBound
      guard let utf8Column = snapshot.lineTable.utf8ColumnAt(line: position.line, utf16Column: position.utf16index)
      else {
        logger.fault("Unable to find UTF-8 column for \(position.line):\(position.utf16index)")
        return nil
      }
      return RenameLocation(line: position.line + 1, utf8Column: utf8Column + 1, usage: relatedIdentifier.usage)
    }

    try Task.checkCancellation()

    let edits = try await editsToRename(
      locations: renameLocations,
      in: snapshot,
      oldName: TranslatableName(
        definitionName: oldName,
        definitionDocumentUri: request.textDocument.uri,
        definitionPosition: request.position,
        definitionLanguageService: self,
        isObjectiveCSelector: false
      ),
      newName: TranslatableName(
        definitionName: request.newName,
        definitionDocumentUri: request.textDocument.uri,
        definitionPosition: request.position,
        definitionLanguageService: self,
        isObjectiveCSelector: false
      )
    )

    try Task.checkCancellation()

    let usr =
      (try? await self.symbolInfo(SymbolInfoRequest(textDocument: request.textDocument, position: request.position)))?
      .only?.usr

    return (edits: WorkspaceEdit(changes: [snapshot.uri: edits]), usr: usr)
  }

  /// Return the edit that needs to be performed for the given syntactic rename piece to rename it from
  /// `oldParameter` to `newParameter`.
  /// Returns `nil` if no edit needs to be performed.
  private func textEdit(
    for piece: SyntacticRenamePiece,
    in snapshot: DocumentSnapshot,
    oldParameter: CompoundDeclName.Parameter,
    newParameter: CompoundDeclName.Parameter
  ) -> TextEdit? {
    switch piece.kind {
    case .parameterName:
      if newParameter == .wildcard, piece.range.isEmpty, case .named(let oldParameterName) = oldParameter {
        // We are changing a named parameter to an unnamed one. If the parameter didn't have an internal parameter
        // name, we need to transfer the previously external parameter name to be the internal one.
        // E.g. `func foo(a: Int)` becomes `func foo(_ a: Int)`.
        return TextEdit(range: piece.range, newText: " " + oldParameterName)
      }
      if let original = snapshot.lineTable[piece.range],
        case .named(let newParameterLabel) = newParameter,
        newParameterLabel.trimmingCharacters(in: .whitespaces) == original.trimmingCharacters(in: .whitespaces)
      {
        // We are changing the external parameter name to be the same one as the internal parameter name. The
        // internal name is thus no longer needed. Drop it.
        // Eg. an old declaration `func foo(_ a: Int)` becomes `func foo(a: Int)` when renaming the parameter to `a`
        return TextEdit(range: piece.range, newText: "")
      }
      // In all other cases, don't touch the internal parameter name. It's not part of the public API.
      return nil
    case .noncollapsibleParameterName:
      // Noncollapsible parameter names should never be renamed because they are the same as `parameterName` but
      // never fall into one of the two categories above.
      return nil
    case .declArgumentLabel:
      if piece.range.isEmpty {
        // If we are inserting a new external argument label where there wasn't one before, add a space after it to
        // separate it from the internal name.
        // E.g. `subscript(a: Int)` becomes `subscript(a a: Int)`.
        return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard + " ")
      }
      // Otherwise, just update the name.
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .callArgumentLabel:
      // Argument labels of calls are just updated.
      return TextEdit(range: piece.range, newText: newParameter.stringOrEmpty)
    case .callArgumentColon:
      if case .wildcard = newParameter {
        // If the parameter becomes unnamed, remove the colon after the argument name.
        return TextEdit(range: piece.range, newText: "")
      }
      return nil
    case .callArgumentCombined:
      if case .named(let newParameterName) = newParameter {
        // If an unnamed parameter becomes named, insert the new name and a colon.
        return TextEdit(range: piece.range, newText: newParameterName + ": ")
      }
      return nil
    case .selectorArgumentLabel:
      return TextEdit(range: piece.range, newText: newParameter.stringOrWildcard)
    case .baseName, .keywordBaseName:
      preconditionFailure("Handled above")
    }
  }

  public func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldTranslatableName: TranslatableName,
    newName newTranslatableName: TranslatableName
  ) async throws -> [TextEdit] {
    // Pick any location for the name translation.
    // They should all refer to the same declaration, so sourcekitd doens't care which one we pick.
    guard let renameLocationForNameTranslation = renameLocations.first else {
      return []
    }
    guard let positionForNameTranslation = snapshot.position(of: renameLocationForNameTranslation) else {
      throw ResponseError.unknown(
        "Unable to get position for first rename location \(snapshot.uri.forLogging):\(renameLocationForNameTranslation.line):\(renameLocationForNameTranslation.utf8Column)"
      )
    }
    let oldNameString = try await oldTranslatableName.swiftName(
      at: positionForNameTranslation,
      in: snapshot,
      languageService: self
    )
    let oldName = CompoundDeclName(oldNameString)
    let newName = try await CompoundDeclName(
      newTranslatableName.swiftName(
        at: positionForNameTranslation,
        in: snapshot,
        languageService: self
      )
    )

    let compoundRenameRanges = try await getSyntacticRenameRanges(
      renameLocations: renameLocations,
      oldName: oldNameString,
      in: snapshot
    )

    try Task.checkCancellation()

    return compoundRenameRanges.flatMap { (compoundRenameRange) -> [TextEdit] in
      switch compoundRenameRange.category {
      case .unmatched, .mismatch:
        // The location didn't match. Don't rename it
        return []
      case .activeCode, .inactiveCode, .selector:
        // Occurrences in active code and selectors should always be renamed.
        // Inactive code is currently never returned by sourcekitd.
        break
      case .string, .comment:
        // We currently never get any results in strings or comments because the related identifiers request doesn't
        // provide any locations inside strings or comments. We would need to have a textual index to find these
        // locations.
        return []
      }
      return compoundRenameRange.pieces.compactMap { (piece) -> TextEdit? in
        if piece.kind == .baseName {
          return TextEdit(range: piece.range, newText: newName.baseName)
        } else if piece.kind == .keywordBaseName {
          // Keyword base names can't be renamed
          return nil
        }

        guard let parameterIndex = piece.parameterIndex,
          parameterIndex < newName.parameters.count,
          parameterIndex < oldName.parameters.count
        else {
          // Be lenient and just keep the old parameter names if the new name doesn't specify them, eg. if we are
          // renaming `func foo(a: Int, b: Int)` and the user specified `bar(x:)` as the new name.
          return nil
        }

        return self.textEdit(
          for: piece,
          in: snapshot,
          oldParameter: oldName.parameters[parameterIndex],
          newParameter: newName.parameters[parameterIndex]
        )
      }
    }
  }

  public func prepareRename(_ request: PrepareRenameRequest) async throws -> PrepareRenameResponse? {
    let snapshot = try self.documentManager.latestSnapshot(request.textDocument.uri)

    let response = try await self.relatedIdentifiers(
      at: request.position,
      in: snapshot,
      includeNonEditableBaseNames: true
    )
    guard let name = response.name else {
      throw ResponseError.unknown("Running sourcekit-lsp with a version of sourcekitd that does not support rename")
    }
    guard let range = response.relatedIdentifiers.first(where: { $0.range.contains(request.position) })?.range
    else {
      return nil
    }
    return PrepareRenameResponse(
      range: range,
      placeholder: name
    )
  }
}

// MARK: - Clang

extension ClangLanguageServerShim {
  func rename(_ renameRequest: RenameRequest) async throws -> (edits: WorkspaceEdit, usr: String?) {
    async let edits = forwardRequestToClangd(renameRequest)
    let symbolInfoRequest = SymbolInfoRequest(
      textDocument: renameRequest.textDocument,
      position: renameRequest.position
    )
    let symbolDetail = try await forwardRequestToClangd(symbolInfoRequest).only
    return (try await edits ?? WorkspaceEdit(), symbolDetail?.usr)
  }

  func editsToRename(
    locations renameLocations: [RenameLocation],
    in snapshot: DocumentSnapshot,
    oldName oldTranslatableName: TranslatableName,
    newName newTranslatableName: TranslatableName
  ) async throws -> [TextEdit] {
    let positions = [
      snapshot.uri: renameLocations.compactMap { snapshot.position(of: $0) }
    ]
    let oldName = try await oldTranslatableName.clangName()
    let newName = try await newTranslatableName.clangName()
    let request = IndexedRenameRequest(
      textDocument: TextDocumentIdentifier(snapshot.uri),
      oldName: oldName,
      newName: newName,
      positions: positions
    )
    do {
      let edits = try await forwardRequestToClangd(request)
      return edits?.changes?[snapshot.uri] ?? []
    } catch {
      logger.error("Failed to get indexed rename edits: \(error.forLogging)")
      return []
    }
  }

  public func prepareRename(_ request: PrepareRenameRequest) async throws -> PrepareRenameResponse? {
    return try await forwardRequestToClangd(request)
  }
}
