import Foundation

public enum XCStringsCatalogError: LocalizedError {
  case invalidCatalog(String)
  case keyNotFound(String)
  case nonManualKey(String)
  case invalidInput(String)
  case sourceLocaleRemoval(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidCatalog(message):
      return "Invalid xcstrings catalog: \(message)"
    case let .keyNotFound(key):
      return "Key not found: \(key)"
    case let .nonManualKey(key):
      return "The key is not editable because it is not a manual entry: \(key)"
    case let .invalidInput(message):
      return "Invalid input: \(message)"
    case let .sourceLocaleRemoval(locale):
      return "Cannot remove source language locale: \(locale)"
    }
  }
}

private typealias JSONObject = [String: Any]
private typealias JSONArray = [Any]

private struct StringUnit {
  var state: String
  var value: String
}

private struct PlaceholderToken: Hashable {
  var raw: String
  var index: Int?
  var valueType: String
}

private enum LocalizationStatus {
  case missing
  case translated
  case incomplete
}

public struct XCStringsCatalog {
  private let originalData: Data?
  private var root: JSONObject

  public init(data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? JSONObject else {
      throw XCStringsCatalogError.invalidCatalog("Top-level JSON object is not a dictionary.")
    }
    guard root["strings"] is JSONObject else {
      throw XCStringsCatalogError.invalidCatalog("Missing top-level \"strings\" dictionary.")
    }
    self.root = root
    originalData = data
  }

  public static func load(from url: URL) throws -> XCStringsCatalog {
    try XCStringsCatalog(data: Data(contentsOf: url))
  }

  public var sourceLanguage: String {
    root["sourceLanguage"] as? String ?? "en"
  }

  public var keys: [String] {
    strings.keys.sorted()
  }

  public func locales() -> LocalesResult {
    LocalesResult(
      sourceLanguage: sourceLanguage,
      locales: detectedLocales(includeAutoExtracted: true)
    )
  }

  /// Returns locales detected from manual keys only, suitable for validation requirements.
  public var validationLocales: [String] {
    detectedLocales(includeAutoExtracted: false)
  }

  public func find(_ query: FindQuery) throws -> [FindResultEntry] {
    guard !query.value.isEmpty else {
      throw XCStringsCatalogError.invalidInput("Find query must not be empty.")
    }
    if query.field != .string, query.locale != nil {
      throw XCStringsCatalogError.invalidInput("--locale is only supported for string searches.")
    }

    let regex: NSRegularExpression?
    if query.match == .regex {
      do {
        regex = try NSRegularExpression(pattern: query.value)
      } catch {
        throw XCStringsCatalogError.invalidInput("Invalid regex: \(error.localizedDescription)")
      }
    } else {
      regex = nil
    }

    var results: [FindResultEntry] = []

    for key in keys {
      guard let entry = strings[key] as? JSONObject else {
        continue
      }

      let entryComment = entry["comment"] as? String
      var matched: [FindMatchedValue] = []

      switch query.field {
      case .key:
        if let actualMatch = actualMatchMode(for: key, query: query.value, mode: query.match, regex: regex) {
          matched.append(FindMatchedValue(field: .key, match: actualMatch))
        }

      case .comment:
        if let entryComment,
          let actualMatch = actualMatchMode(for: entryComment, query: query.value, mode: query.match, regex: regex) {
          matched.append(FindMatchedValue(field: .comment, value: entryComment, match: actualMatch))
        }

      case .string:
        let localizations = entry["localizations"] as? JSONObject ?? [:]
        let localesToSearch = query.locale.map { [$0] } ?? localizations.keys.sorted()

        for locale in localesToSearch {
          guard let localization = localizations[locale] else {
            continue
          }

          for unit in stringUnits(in: localization) {
            guard let actualMatch = actualMatchMode(
              for: unit.value,
              query: query.value,
              mode: query.match,
              regex: regex
            ) else {
              continue
            }

            let match = FindMatchedValue(
              field: .string,
              locale: locale,
              value: unit.value,
              match: actualMatch
            )
            if !matched.contains(match) {
              matched.append(match)
            }
          }
        }
      }

      if !matched.isEmpty {
        matched.sort { lhs, rhs in
          let lhsLocale = lhs.locale ?? ""
          let rhsLocale = rhs.locale ?? ""
          if lhsLocale != rhsLocale {
            return lhsLocale < rhsLocale
          }
          if lhs.field.rawValue != rhs.field.rawValue {
            return lhs.field.rawValue < rhs.field.rawValue
          }
          if lhs.match.rawValue != rhs.match.rawValue {
            return lhs.match.rawValue < rhs.match.rawValue
          }
          return (lhs.value ?? "") < (rhs.value ?? "")
        }

        results.append(
          FindResultEntry(
            key: key,
            extractionState: extractionState(for: entry),
            comment: entryComment,
            matched: matched
          )
        )
      }
    }

    return results
  }

  public func show(key: String) throws -> ShowResult {
    guard let entry = strings[key] as? JSONObject else {
      throw XCStringsCatalogError.keyNotFound(key)
    }

    let rawLocalizations = entry["localizations"] as? JSONObject ?? [:]
    var localizations: [String: [ShowLocalizationValue]] = [:]

    for locale in rawLocalizations.keys.sorted() {
      guard let localization = rawLocalizations[locale] else {
        continue
      }
      localizations[locale] = stringUnits(in: localization).map {
        ShowLocalizationValue(state: $0.state, value: $0.value)
      }
    }

    return ShowResult(
      key: key,
      extractionState: extractionState(for: entry),
      comment: entry["comment"] as? String,
      shouldTranslate: shouldTranslate(for: entry),
      localizations: localizations
    )
  }

  public func inspect() -> InspectResult {
    let descriptors = keys.compactMap { key -> CatalogKeyDescriptor? in
      guard let entry = strings[key] as? JSONObject else {
        return nil
      }
      let localizations = (entry["localizations"] as? JSONObject)?.keys.sorted() ?? []
      return CatalogKeyDescriptor(
        key: key,
        extractionState: extractionState(for: entry),
        shouldTranslate: shouldTranslate(for: entry),
        locales: localizations
      )
    }

    return InspectResult(
      sourceLanguage: sourceLanguage,
      locales: detectedLocales(includeAutoExtracted: true),
      keyCount: descriptors.count,
      manualKeyCount: descriptors.filter { $0.extractionState == "manual" }.count,
      autoKeyCount: descriptors.filter { $0.extractionState != "manual" }.count,
      translatableKeyCount: descriptors.filter(\.shouldTranslate).count,
      keys: descriptors
    )
  }

  public func validate(
    requiredLocales explicitRequiredLocales: [String]? = nil,
    strict: Bool = false
  ) -> ValidationResult {
    let requiredLocales = (explicitRequiredLocales ?? detectedLocales(includeAutoExtracted: false)).sorted()
    var errors: [ValidationIssue] = []
    var warnings: [ValidationIssue] = []

    for key in keys {
      guard let entry = strings[key] as? JSONObject else {
        errors.append(
          ValidationIssue(
            severity: .error,
            code: "invalid_entry",
            key: key,
            message: "Entry is not a JSON object."
          )
        )
        continue
      }

      if !shouldTranslate(for: entry) {
        continue
      }

      let extractionState = extractionState(for: entry)
      let localizations = entry["localizations"] as? JSONObject ?? [:]

      if extractionState != "manual" {
        if key.isEmpty {
          warnings.append(
            ValidationIssue(
              severity: .warning,
              code: "stale_auto_extracted_key",
              key: key,
              message: "Empty auto-extracted key is likely stale."
            )
          )
        }

        appendTranslationIssues(
          to: &errors,
          warnings: &warnings,
          key: key,
          localizations: localizations,
          requiredLocales: requiredLocales,
          sourceLanguage: sourceLanguage,
          strict: strict,
          extractionState: extractionState
        )
        continue
      }

      appendTranslationIssues(
        to: &errors,
        warnings: &warnings,
        key: key,
        localizations: localizations,
        requiredLocales: requiredLocales,
        sourceLanguage: sourceLanguage,
        strict: strict,
        extractionState: extractionState
      )
    }

    errors.sort { issueSortKey($0) < issueSortKey($1) }
    warnings.sort { issueSortKey($0) < issueSortKey($1) }

    return ValidationResult(
      sourceLanguage: sourceLanguage,
      requiredLocales: requiredLocales,
      errors: errors,
      warnings: warnings
    )
  }

  @discardableResult
  public mutating func upsert(_ input: EntryInput) throws -> MutationSummary {
    guard !input.key.isEmpty else {
      throw XCStringsCatalogError.invalidInput("Key must not be empty.")
    }
    guard input.extractionState == "manual" else {
      throw XCStringsCatalogError.invalidInput("Only manual entries are supported.")
    }

    let previousEntry = strings[input.key]
    if
      let previousEntry,
      let dictionary = previousEntry as? JSONObject,
      extractionState(for: dictionary) != "manual"
    {
      throw XCStringsCatalogError.nonManualKey(input.key)
    }
    if previousEntry == nil && input.localizations.isEmpty {
      throw XCStringsCatalogError.invalidInput("Adding a new key requires at least one localization.")
    }

    var entry = (previousEntry as? JSONObject) ?? [:]
    entry["extractionState"] = "manual"

    if let comment = input.comment {
      if comment.isEmpty {
        entry.removeValue(forKey: "comment")
      } else {
        entry["comment"] = comment
      }
    }

    if let shouldTranslate = input.shouldTranslate {
      if shouldTranslate {
        entry.removeValue(forKey: "shouldTranslate")
      } else {
        entry["shouldTranslate"] = false
      }
    }

    var localizations = entry["localizations"] as? JSONObject ?? [:]
    for locale in input.localizations.keys.sorted() {
      guard let localization = input.localizations[locale] else {
        continue
      }
      localizations[locale] = [
        "stringUnit": [
          "state": localization.state,
          "value": localization.value,
        ],
      ]
    }
    entry["localizations"] = localizations
    strings[input.key] = entry

    var summary = MutationSummary()
    if previousEntry == nil {
      summary.recordAdded(input.key)
    } else if try canonicalJSONData(for: previousEntry as Any) != canonicalJSONData(for: entry) {
      summary.recordUpdated(input.key)
    }
    summary.finalize()
    return summary
  }

  @discardableResult
  public mutating func remove(key: String) throws -> MutationSummary {
    guard let existing = strings[key] as? JSONObject else {
      throw XCStringsCatalogError.keyNotFound(key)
    }
    guard extractionState(for: existing) == "manual" else {
      throw XCStringsCatalogError.nonManualKey(key)
    }

    strings.removeValue(forKey: key)

    var summary = MutationSummary()
    summary.recordRemoved(key)
    summary.finalize()
    return summary
  }

  @discardableResult
  public mutating func addLocale(
    _ locale: String,
    copyFrom: String? = nil,
    state: String = "new"
  ) throws -> MutationSummary {
    guard !locale.isEmpty else {
      throw XCStringsCatalogError.invalidInput("Locale must not be empty.")
    }

    var touched = false
    for key in keys {
      guard var entry = strings[key] as? JSONObject else {
        continue
      }
      guard extractionState(for: entry) == "manual", shouldTranslate(for: entry) else {
        continue
      }

      var localizations = entry["localizations"] as? JSONObject ?? [:]
      if localizations[locale] != nil {
        continue
      }

      if let copyFrom, let copied = localizations[copyFrom] {
        localizations[locale] = updatedLocalizationState(copied, state: state)
      } else {
        localizations[locale] = [
          "stringUnit": [
            "state": state,
            "value": "",
          ],
        ]
      }
      entry["localizations"] = localizations
      strings[key] = entry
      touched = true
    }

    var summary = MutationSummary()
    if touched {
      summary.recordLocaleAdded(locale)
    }
    summary.finalize()
    return summary
  }

  @discardableResult
  public mutating func removeLocale(_ locale: String) throws -> MutationSummary {
    guard locale != sourceLanguage else {
      throw XCStringsCatalogError.sourceLocaleRemoval(locale)
    }

    var touched = false
    for key in keys {
      guard var entry = strings[key] as? JSONObject else {
        continue
      }
      guard extractionState(for: entry) == "manual" else {
        continue
      }

      var localizations = entry["localizations"] as? JSONObject ?? [:]
      if localizations.removeValue(forKey: locale) != nil {
        entry["localizations"] = localizations
        strings[key] = entry
        touched = true
      }
    }

    var summary = MutationSummary()
    if touched {
      summary.recordLocaleRemoved(locale)
    }
    summary.finalize()
    return summary
  }

  public func formattedData() throws -> Data {
    guard JSONSerialization.isValidJSONObject(root) else {
      throw XCStringsCatalogError.invalidCatalog("Catalog contains non-JSON values.")
    }
    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    return data
  }

  public func wouldChangeOnWrite() throws -> Bool {
    let formatted = try formattedData()
    return formatted != originalData
  }

  public func write(to url: URL) throws {
    try formattedData().write(to: url, options: .atomic)
  }

  private var strings: JSONObject {
    get { root["strings"] as? JSONObject ?? [:] }
    set { root["strings"] = newValue }
  }

  private func extractionState(for entry: JSONObject) -> String {
    entry["extractionState"] as? String ?? ""
  }

  private func shouldTranslate(for entry: JSONObject) -> Bool {
    (entry["shouldTranslate"] as? Bool) ?? true
  }

  private func detectedLocales(includeAutoExtracted: Bool) -> [String] {
    var locales: Set<String> = [sourceLanguage]
    for key in keys {
      guard let entry = strings[key] as? JSONObject else {
        continue
      }
      if !includeAutoExtracted && extractionState(for: entry) != "manual" {
        continue
      }
      let localizationKeys = Array((entry["localizations"] as? JSONObject ?? [:]).keys)
      locales.formUnion(localizationKeys)
    }
    return locales.sorted()
  }

  private func appendTranslationIssues(
    to errors: inout [ValidationIssue],
    warnings: inout [ValidationIssue],
    key: String,
    localizations: JSONObject,
    requiredLocales: [String],
    sourceLanguage: String,
    strict: Bool,
    extractionState: String
  ) {
    for locale in requiredLocales {
      let status = localizationStatus(
        localization: localizations[locale],
        locale: locale,
        sourceLanguage: sourceLanguage,
        localizations: localizations
      )

      switch status {
      case .missing:
        errors.append(
          ValidationIssue(
            severity: .error,
            code: "missing_translation",
            key: key,
            locale: locale,
            message: "Missing translation."
          )
        )
      case .incomplete:
        errors.append(
          ValidationIssue(
            severity: .error,
            code: "incomplete_translation",
            key: key,
            locale: locale,
            message: "Translation exists but is not in the translated state."
          )
        )
      case .translated:
        break
      }
    }

    let sourceSignatures = sourcePlaceholderSignatures(
      key: key,
      localizations: localizations,
      sourceLanguage: sourceLanguage
    )

    for locale in localizations.keys.sorted() {
      guard let localization = localizations[locale] else {
        continue
      }

      let units = stringUnits(in: localization)
      if units.isEmpty {
        warnings.append(
          ValidationIssue(
            severity: .warning,
            code: "empty_localization",
            key: key,
            locale: locale,
            message: "Localization exists but contains no translatable values."
          )
        )
        continue
      }

      for unit in units {
        if unit.value.isEmpty {
          errors.append(
            ValidationIssue(
              severity: .error,
              code: "empty_translation",
              key: key,
              locale: locale,
              message: "Translation value is empty."
            )
          )
        }

        if unit.state != "translated" {
          // Source language with non-empty value is OK even if state is "new"
          // (normal for auto-extracted entries like extracted_with_value).
          let isSourceLangOK = locale == sourceLanguage && !unit.value.isEmpty
          if !isSourceLangOK {
            let issue = ValidationIssue(
              severity: strict || extractionState == "manual" ? .error : .warning,
              code: "translation_not_translated",
              key: key,
              locale: locale,
              message: "Translation state is \(unit.state)."
            )
            if issue.severity == .error {
              errors.append(issue)
            } else {
              warnings.append(issue)
            }
          }
        }

        let signature = placeholderSignature(in: unit.value)
        if !sourceSignatures.contains(signature) {
          errors.append(
            ValidationIssue(
              severity: .error,
              code: "placeholder_mismatch",
              key: key,
              locale: locale,
              message: "Placeholder sequence \(signature) does not match source placeholders \(Array(sourceSignatures))."
            )
          )
        }
      }
    }
  }

  private func localizationStatus(
    localization: Any?,
    locale: String,
    sourceLanguage: String,
    localizations: JSONObject
  ) -> LocalizationStatus {
    if localization == nil {
      if locale == sourceLanguage && !localizations.isEmpty {
        return .translated
      }
      return .missing
    }

    let units = stringUnits(in: localization as Any)
    if units.isEmpty {
      return .missing
    }
    if units.allSatisfy({ !$0.value.isEmpty && $0.state == "translated" }) {
      return .translated
    }
    // Source language with non-empty values is considered translated even if
    // the state is "new" (common for extracted_with_value entries).
    if locale == sourceLanguage && units.allSatisfy({ !$0.value.isEmpty }) {
      return .translated
    }
    return .incomplete
  }

  private func sourcePlaceholderSignatures(
    key: String,
    localizations: JSONObject,
    sourceLanguage: String
  ) -> Set<[String]> {
    if let sourceLocalization = localizations[sourceLanguage] {
      let signatures = Set(stringUnits(in: sourceLocalization).map { placeholderSignature(in: $0.value) })
      if !signatures.isEmpty {
        return signatures
      }
    }
    return [placeholderSignature(in: key)]
  }

  private func stringUnits(in value: Any) -> [StringUnit] {
    if let dictionary = value as? JSONObject {
      var units: [StringUnit] = []

      if let stringUnit = dictionary["stringUnit"] as? JSONObject {
        units.append(
          StringUnit(
            state: stringUnit["state"] as? String ?? "",
            value: stringUnit["value"] as? String ?? ""
          )
        )
      }

      if let stringSet = dictionary["stringSet"] as? JSONObject {
        let state = stringSet["state"] as? String ?? ""
        let values = stringSet["values"] as? [String] ?? []
        for setValue in values {
          units.append(StringUnit(state: state, value: setValue))
        }
      }

      for nestedValue in dictionary.values {
        switch nestedValue {
        case is JSONObject, is JSONArray:
          units.append(contentsOf: stringUnits(in: nestedValue))
        default:
          break
        }
      }
      return units
    }

    if let array = value as? JSONArray {
      return array.flatMap { stringUnits(in: $0) }
    }

    return []
  }

  private func updatedLocalizationState(_ value: Any, state: String) -> Any {
    if var dictionary = value as? JSONObject {
      if var stringUnit = dictionary["stringUnit"] as? JSONObject {
        stringUnit["state"] = state
        dictionary["stringUnit"] = stringUnit
      }

      if var stringSet = dictionary["stringSet"] as? JSONObject {
        stringSet["state"] = state
        dictionary["stringSet"] = stringSet
      }

      for key in dictionary.keys.sorted() {
        guard let nested = dictionary[key] else {
          continue
        }
        switch nested {
        case is JSONObject, is JSONArray:
          dictionary[key] = updatedLocalizationState(nested, state: state)
        default:
          continue
        }
      }
      return dictionary
    }

    if let array = value as? JSONArray {
      return array.map { updatedLocalizationState($0, state: state) }
    }

    return value
  }

  private func placeholderSignature(in string: String) -> [String] {
    let tokens = placeholderTokens(in: string)
    guard !tokens.isEmpty else {
      return []
    }

    if tokens.allSatisfy({ $0.index != nil }) {
      return tokens
        .sorted {
          if $0.index != $1.index {
            return ($0.index ?? 0) < ($1.index ?? 0)
          }
          if $0.valueType != $1.valueType {
            return $0.valueType < $1.valueType
          }
          return $0.raw < $1.raw
        }
        .map { "%\($0.index!)$\($0.valueType)" }
    }

    return tokens.map(\.raw)
  }

  private func placeholderTokens(in string: String) -> [PlaceholderToken] {
    let pattern = #"%(?:(\d+)\$)?(lld|ld|d|f|@)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    return regex.matches(in: string, range: range).compactMap { match in
      guard let fullRange = Range(match.range(at: 0), in: string),
        let typeRange = Range(match.range(at: 2), in: string)
      else {
        return nil
      }

      let raw = String(string[fullRange])
      let valueType = String(string[typeRange])
      let index: Int?
      if let indexRange = Range(match.range(at: 1), in: string) {
        index = Int(string[indexRange])
      } else {
        index = nil
      }

      return PlaceholderToken(raw: raw, index: index, valueType: valueType)
    }
  }

  private func actualMatchMode(
    for candidate: String,
    query: String,
    mode: FindMatchMode,
    regex: NSRegularExpression?
  ) -> FindMatchMode? {
    switch mode {
    case .exact:
      return candidate == query ? .exact : nil

    case .prefix:
      guard candidate.hasPrefix(query) else {
        return nil
      }
      return candidate == query ? .exact : .prefix

    case .suffix:
      guard candidate.hasSuffix(query) else {
        return nil
      }
      return candidate == query ? .exact : .suffix

    case .contains:
      guard candidate.contains(query) else {
        return nil
      }
      if candidate == query {
        return .exact
      }
      if candidate.hasPrefix(query) {
        return .prefix
      }
      if candidate.hasSuffix(query) {
        return .suffix
      }
      return .contains

    case .regex:
      guard let regex else {
        return nil
      }
      let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
      return regex.firstMatch(in: candidate, range: range) == nil ? nil : .regex
    }
  }

  private func issueSortKey(_ issue: ValidationIssue) -> String {
    "\(issue.severity.rawValue)|\(issue.code)|\(issue.key ?? "")|\(issue.locale ?? "")|\(issue.message)"
  }

  private func canonicalJSONData(for value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw XCStringsCatalogError.invalidCatalog("Value cannot be serialized as JSON.")
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
}
