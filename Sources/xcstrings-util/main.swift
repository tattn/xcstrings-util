import Foundation
import Darwin
import XCStringsUtilCore

private enum ExitCode: Int32 {
  case success = 0
  case validationFailed = 1
  case invalidArguments = 2
  case ioFailure = 3
  case commandFailed = 4
}

private struct ParsedArguments {
  var positionals: [String] = []
  var flags: Set<String> = []
  var options: [String: String] = [:]

  func hasFlag(_ name: String) -> Bool {
    flags.contains(name)
  }

  func value(for option: String) -> String? {
    options[option]
  }
}

private enum Command {
  case locales(path: String)
  case inspect(path: String)
  case find(path: String, query: FindQuery)
  case show(path: String, key: String)
  case validate(path: String, strict: Bool, requiredLocales: [String]?)
  case upsert(path: String, key: String, comment: String?, inputSource: InputSource?, dryRun: Bool)
  case remove(path: String, key: String, dryRun: Bool)
  case localeAdd(path: String, locale: String, copyFrom: String?, state: String, dryRun: Bool)
  case localeRemove(path: String, locale: String, dryRun: Bool)
}

private enum InputSource {
  case data(Data)
  case file(URL)
}

@main
struct XCStringsUtilCLI {
  static func main() {
    do {
      let stdinData = readOptionalStdinData()
      let parsed = try parseCommandLine(Array(CommandLine.arguments.dropFirst()))
      let outputFormat = parsed.options["format"].flatMap(OutputFormat.init(rawValue:)) ?? (parsed.flags.contains("json") ? .json : .text)
      let command = try makeCommand(from: parsed, stdinData: stdinData)
      let exitCode = try run(command: command, outputFormat: outputFormat)
      Foundation.exit(exitCode.rawValue)
    } catch let error as XCStringsCatalogError {
      writeError(error.localizedDescription)
      Foundation.exit(ExitCode.commandFailed.rawValue)
    } catch let error as CLIError {
      writeError(error.localizedDescription)
      Foundation.exit(error.exitCode.rawValue)
    } catch {
      writeError(error.localizedDescription)
      Foundation.exit(ExitCode.commandFailed.rawValue)
    }
  }

  private static func run(command: Command, outputFormat: OutputFormat) throws -> ExitCode {
    switch command {
    case let .locales(path):
      let catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let result = catalog.locales()
      try render(result, format: outputFormat) {
        """
        Source language: \(result.sourceLanguage)
        Locales: \(result.locales.joined(separator: ", "))
        """
      }
      return .success

    case let .inspect(path):
      let catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let result = catalog.inspect()
      try render(result, format: outputFormat) {
        """
        Source language: \(result.sourceLanguage)
        Locales: \(result.locales.joined(separator: ", "))
        Keys: \(result.keyCount) total (\(result.manualKeyCount) manual / \(result.autoKeyCount) auto)
        Translatable: \(result.translatableKeyCount)
        """
      }
      return .success

    case let .find(path, query):
      let catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let result = try catalog.find(query)
      try render(result, format: outputFormat) {
        result
          .flatMap { entry in
            entry.matched.map { match in
              [
                entry.key,
                entry.extractionState,
                match.field.rawValue,
                match.locale ?? "-",
                match.match.rawValue,
                match.value ?? "-",
              ].joined(separator: "\t")
            }
          }
          .joined(separator: "\n")
      }
      return .success

    case let .show(path, key):
      let catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let result = try catalog.show(key: key)
      try render(result, format: outputFormat) {
        var lines = [
          "key: \(result.key)",
          "extractionState: \(result.extractionState)",
          "shouldTranslate: \(result.shouldTranslate)",
        ]
        if let comment = result.comment {
          lines.insert("comment: \(comment)", at: 2)
        }
        for locale in result.localizations.keys.sorted() {
          let values = result.localizations[locale] ?? []
          if values.isEmpty {
            lines.append("\(locale): []")
            continue
          }
          for value in values {
            lines.append("\(locale) [\(value.state)]: \(value.value)")
          }
        }
        return lines.joined(separator: "\n")
      }
      return .success

    case let .validate(path, strict, requiredLocales):
      let catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let result = catalog.validate(requiredLocales: requiredLocales, strict: strict)
      try render(result, format: outputFormat) {
        var lines = [
          "Source language: \(result.sourceLanguage)",
          "Required locales: \(result.requiredLocales.joined(separator: ", "))",
          "Errors: \(result.errors.count)",
          "Warnings: \(result.warnings.count)",
        ]
        if !result.errors.isEmpty {
          lines.append(contentsOf: result.errors.prefix(10).map { issue in
            "ERROR [\(issue.code)] \(issue.key ?? "-") \(issue.locale ?? "-"): \(issue.message)"
          })
        }
        if !result.warnings.isEmpty {
          lines.append(contentsOf: result.warnings.prefix(10).map { issue in
            "WARN [\(issue.code)] \(issue.key ?? "-") \(issue.locale ?? "-"): \(issue.message)"
          })
        }
        return lines.joined(separator: "\n")
      }
      return result.isSuccess ? .success : .validationFailed

    case let .upsert(path, key, comment, inputSource, dryRun):
      var catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let payload = try decodeUpsertInput(key: key, comment: comment, from: inputSource)
      let summary = try catalog.upsert(payload)
      let changed = try writeCatalogIfNeeded(&catalog, to: path, dryRun: dryRun)
      let validation = catalog.validate()
      let result = MutationResult(
        changed: changed,
        dryRun: dryRun,
        summary: summary,
        validation: validation
      )
      try render(result, format: outputFormat) {
        """
        Changed: \(result.changed)
        Dry run: \(result.dryRun)
        Added: \(result.summary.added.joined(separator: ", "))
        Updated: \(result.summary.updated.joined(separator: ", "))
        Validation errors: \(result.validation.errors.count)
        Validation warnings: \(result.validation.warnings.count)
        """
      }
      return validation.isSuccess ? .success : .validationFailed

    case let .remove(path, key, dryRun):
      var catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let summary = try catalog.remove(key: key)
      let changed = try writeCatalogIfNeeded(&catalog, to: path, dryRun: dryRun)
      let validation = catalog.validate()
      let result = MutationResult(
        changed: changed,
        dryRun: dryRun,
        summary: summary,
        validation: validation
      )
      try render(result, format: outputFormat) {
        """
        Changed: \(result.changed)
        Dry run: \(result.dryRun)
        Removed: \(result.summary.removed.joined(separator: ", "))
        Validation errors: \(result.validation.errors.count)
        Validation warnings: \(result.validation.warnings.count)
        """
      }
      return validation.isSuccess ? .success : .validationFailed

    case let .localeAdd(path, locale, copyFrom, state, dryRun):
      var catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let summary = try catalog.addLocale(locale, copyFrom: copyFrom, state: state)
      let changed = try writeCatalogIfNeeded(&catalog, to: path, dryRun: dryRun)
      let validation = catalog.validate()
      let result = MutationResult(
        changed: changed,
        dryRun: dryRun,
        summary: summary,
        validation: validation
      )
      try render(result, format: outputFormat) {
        """
        Changed: \(result.changed)
        Dry run: \(result.dryRun)
        Locale added: \(locale)
        Copy from: \(copyFrom ?? "-")
        State: \(state)
        Validation errors: \(result.validation.errors.count)
        Validation warnings: \(result.validation.warnings.count)
        """
      }
      return validation.isSuccess ? .success : .validationFailed

    case let .localeRemove(path, locale, dryRun):
      var catalog = try XCStringsCatalog.load(from: URL(fileURLWithPath: path))
      let summary = try catalog.removeLocale(locale)
      let changed = try writeCatalogIfNeeded(&catalog, to: path, dryRun: dryRun)
      let validation = catalog.validate()
      let result = MutationResult(
        changed: changed,
        dryRun: dryRun,
        summary: summary,
        validation: validation
      )
      try render(result, format: outputFormat) {
        """
        Changed: \(result.changed)
        Dry run: \(result.dryRun)
        Locale removed: \(locale)
        Validation errors: \(result.validation.errors.count)
        Validation warnings: \(result.validation.warnings.count)
        """
      }
      return validation.isSuccess ? .success : .validationFailed

    }
  }

  private static func render<T: Encodable>(
    _ value: T,
    format: OutputFormat,
    textRenderer: () -> String
  ) throws {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(value)
      writeOutput(data)
      writeOutput(Data([0x0A]))
    case .text:
      writeOutput(Data(textRenderer().utf8))
      writeOutput(Data([0x0A]))
    }
  }

  private static func readInputData(from source: InputSource) throws -> Data {
    switch source {
    case let .data(data):
      return data
    case let .file(url):
      return try Data(contentsOf: url)
    }
  }

  private static func readOptionalStdinData() -> Data? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else {
      return nil
    }
    guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else {
      return nil
    }
    return data
  }

  private static func decodeUpsertInput(
    key: String,
    comment: String?,
    from source: InputSource?
  ) throws -> EntryInput {
    guard let source else {
      return EntryInput(key: key, comment: comment, localizations: [:])
    }

    let data = try readInputData(from: source)
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw CLIError("Failed to decode JSON input: \(error.localizedDescription)", exitCode: .invalidArguments)
    }

    guard let dictionary = object as? [String: Any] else {
      throw CLIError("upsert input must be a JSON object keyed by locale.", exitCode: .invalidArguments)
    }

    var localizations: [String: LocalizationInput] = [:]
    let decoder = JSONDecoder()

    for locale in dictionary.keys.sorted() {
      guard let rawValue = dictionary[locale] else {
        continue
      }

      if let value = rawValue as? String {
        localizations[locale] = LocalizationInput(value: value)
        continue
      }

      guard JSONSerialization.isValidJSONObject(rawValue) else {
        throw CLIError(
          "Locale \(locale) must be a string or an object like {\"value\": \"...\", \"state\": \"translated\"}.",
          exitCode: .invalidArguments
        )
      }

      let localizationData = try JSONSerialization.data(withJSONObject: rawValue)
      do {
        localizations[locale] = try decoder.decode(LocalizationInput.self, from: localizationData)
      } catch {
        throw CLIError(
          "Failed to decode locale \(locale): \(error.localizedDescription)",
          exitCode: .invalidArguments
        )
      }
    }

    return EntryInput(key: key, comment: comment, localizations: localizations)
  }

  private static func writeCatalogIfNeeded(
    _ catalog: inout XCStringsCatalog,
    to path: String,
    dryRun: Bool
  ) throws -> Bool {
    let changed = try catalog.wouldChangeOnWrite()
    if !dryRun {
      try catalog.write(to: URL(fileURLWithPath: path))
    }
    return changed
  }

  private static func parseCommandLine(_ arguments: [String]) throws -> ParsedArguments {
    guard !arguments.isEmpty else {
      throw CLIError(helpText(), exitCode: .invalidArguments)
    }

    var parsed = ParsedArguments()
    let flagNames: Set<String> = ["json", "dry-run", "write", "stdin", "strict", "help"]
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]

      if argument.hasPrefix("--") {
        let stripped = String(argument.dropFirst(2))
        if let equalsIndex = stripped.firstIndex(of: "=") {
          let key = String(stripped[..<equalsIndex])
          let value = String(stripped[stripped.index(after: equalsIndex)...])
          parsed.options[key] = value
          index += 1
          continue
        }

        if flagNames.contains(stripped) {
          parsed.flags.insert(stripped)
          index += 1
          continue
        }

        let nextIndex = index + 1
        guard nextIndex < arguments.count else {
          throw CLIError("Missing value for option --\(stripped).", exitCode: .invalidArguments)
        }
        parsed.options[stripped] = arguments[nextIndex]
        index += 2
        continue
      }

      parsed.positionals.append(argument)
      index += 1
    }

    if parsed.flags.contains("help") {
      throw CLIError(helpText(), exitCode: .success)
    }
    if parsed.flags.contains("write") {
      throw CLIError(
        "`--write` has been removed. Mutation commands now write by default. Use `--dry-run` to preview changes.",
        exitCode: .invalidArguments
      )
    }
    return parsed
  }

  private static func makeCommand(from parsed: ParsedArguments, stdinData: Data?) throws -> Command {
    guard let verb = parsed.positionals.first else {
      throw CLIError(helpText(), exitCode: .invalidArguments)
    }

    switch verb {
    case "locales":
      return .locales(path: try positionalPath(at: 1, parsed: parsed))

    case "inspect":
      return .inspect(path: try positionalPath(at: 1, parsed: parsed))

    case "find":
      return .find(
        path: try positionalPath(at: 1, parsed: parsed),
        query: try findQuery(from: parsed)
      )

    case "show":
      guard let key = parsed.value(for: "key"), !key.isEmpty else {
        throw CLIError("show requires --key.", exitCode: .invalidArguments)
      }
      return .show(
        path: try positionalPath(at: 1, parsed: parsed),
        key: key
      )

    case "validate":
      let requiredLocales = parsed.value(for: "required-locales")?
        .split(separator: ",")
        .map { String($0) }
        .filter { !$0.isEmpty }
      return .validate(
        path: try positionalPath(at: 1, parsed: parsed),
        strict: parsed.hasFlag("strict"),
        requiredLocales: requiredLocales
      )

    case "upsert":
      guard let key = parsed.value(for: "key"), !key.isEmpty else {
        throw CLIError("upsert requires --key.", exitCode: .invalidArguments)
      }
      return .upsert(
        path: try positionalPath(at: 1, parsed: parsed),
        key: key,
        comment: parsed.value(for: "comment"),
        inputSource: try upsertInputSource(from: parsed, stdinData: stdinData),
        dryRun: parsed.hasFlag("dry-run")
      )

    case "remove":
      guard let key = parsed.value(for: "key") else {
        throw CLIError("remove requires --key.", exitCode: .invalidArguments)
      }
      return .remove(
        path: try positionalPath(at: 1, parsed: parsed),
        key: key,
        dryRun: parsed.hasFlag("dry-run")
      )

    case "locale":
      guard parsed.positionals.count >= 3 else {
        throw CLIError("locale requires a subcommand: add or remove.", exitCode: .invalidArguments)
      }
      let subcommand = parsed.positionals[1]
      let path = parsed.positionals[2]
      guard let locale = parsed.value(for: "locale") else {
        throw CLIError("locale \(subcommand) requires --locale.", exitCode: .invalidArguments)
      }

      switch subcommand {
      case "add":
        return .localeAdd(
          path: path,
          locale: locale,
          copyFrom: parsed.value(for: "copy-from"),
          state: parsed.value(for: "state") ?? "new",
          dryRun: parsed.hasFlag("dry-run")
        )
      case "remove":
        return .localeRemove(
          path: path,
          locale: locale,
          dryRun: parsed.hasFlag("dry-run")
        )
      default:
        throw CLIError("Unknown locale subcommand: \(subcommand)", exitCode: .invalidArguments)
      }

    default:
      throw CLIError("Unknown command: \(verb)\n\n\(helpText())", exitCode: .invalidArguments)
    }
  }

  private static func positionalPath(at index: Int, parsed: ParsedArguments) throws -> String {
    guard parsed.positionals.count > index else {
      throw CLIError("Missing xcstrings path.\n\n\(helpText())", exitCode: .invalidArguments)
    }
    return parsed.positionals[index]
  }

  private static func findQuery(from parsed: ParsedArguments) throws -> FindQuery {
    let selectors = [
      (FindField.key, parsed.value(for: "key")),
      (FindField.string, parsed.value(for: "string")),
      (FindField.comment, parsed.value(for: "comment")),
    ]
    .compactMap { field, value -> (FindField, String)? in
      guard let value, !value.isEmpty else {
        return nil
      }
      return (field, value)
    }

    guard selectors.count == 1, let selector = selectors.first else {
      throw CLIError("find requires exactly one of --key, --string, or --comment.", exitCode: .invalidArguments)
    }

    let match: FindMatchMode
    if let rawMatch = parsed.value(for: "match") {
      guard let parsedMatch = FindMatchMode(rawValue: rawMatch) else {
        throw CLIError(
          "Unsupported match mode. Use exact, contains, prefix, suffix, or regex.",
          exitCode: .invalidArguments
        )
      }
      match = parsedMatch
    } else {
      match = .exact
    }

    let locale = parsed.value(for: "locale")
    if selector.0 != .string, locale != nil {
      throw CLIError("--locale can only be used with --string.", exitCode: .invalidArguments)
    }

    return FindQuery(field: selector.0, value: selector.1, locale: locale, match: match)
  }

  private static func upsertInputSource(from parsed: ParsedArguments, stdinData: Data?) throws -> InputSource? {
    if let inputPath = parsed.value(for: "input") {
      return .file(URL(fileURLWithPath: inputPath))
    }
    if parsed.hasFlag("stdin") {
      guard let stdinData else {
        throw CLIError("STDIN is empty.", exitCode: .invalidArguments)
      }
      return .data(stdinData)
    }
    if let stdinData {
      return .data(stdinData)
    }
    if parsed.value(for: "comment") != nil {
      return nil
    }
    throw CLIError(
      "Expected JSON on stdin, or pass --input <file>. Use --comment for comment-only updates.",
      exitCode: .invalidArguments
    )
  }

  private static func helpText() -> String {
    """
    xcstrings-util

    Usage:
      xcstrings-util locales <path> [--json]
      xcstrings-util inspect <path> [--json]
      xcstrings-util find <path> (--key <key> | --string <text> | --comment <text>) [--locale <locale>] [--match exact|contains|prefix|suffix|regex] [--json]
      xcstrings-util show <path> --key <key> [--json]
      xcstrings-util validate <path> [--strict] [--required-locales en,ja] [--json]
      xcstrings-util upsert <path> --key <key> [--comment <text>] [--input <file>] [--dry-run] [--json]
      xcstrings-util remove <path> --key <key> [--dry-run] [--json]
      xcstrings-util locale add <path> --locale <locale> [--copy-from <locale>] [--state new|needs_review|translated] [--dry-run] [--json]
      xcstrings-util locale remove <path> --locale <locale> [--dry-run] [--json]

    Notes:
      - Mutation commands write by default unless --dry-run is present.
      - Mutation commands always rewrite files in Xcode-compatible xcstrings formatting.
      - If --input is omitted for upsert, JSON is read from stdin unless it is a comment-only update.
      - validate exits with status 1 when validation errors are present.
    """
  }

  private static func writeOutput(_ data: Data) {
    FileHandle.standardOutput.write(data)
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
    FileHandle.standardError.write(Data([0x0A]))
  }
}

private struct CLIError: LocalizedError {
  let message: String
  let exitCode: ExitCode

  init(_ message: String, exitCode: ExitCode) {
    self.message = message
    self.exitCode = exitCode
  }

  var errorDescription: String? { message }
}
