import Foundation

public enum OutputFormat: String, CaseIterable, Codable {
  case text
  case json
}

public struct LocalizationInput: Codable, Equatable {
  public var value: String
  public var state: String

  public init(value: String, state: String = "translated") {
    self.value = value
    self.state = state
  }
}

public struct EntryInput: Codable, Equatable {
  public var key: String
  public var comment: String?
  public var extractionState: String
  public var shouldTranslate: Bool?
  public var localizations: [String: LocalizationInput]

  public init(
    key: String,
    comment: String? = nil,
    extractionState: String = "manual",
    shouldTranslate: Bool? = nil,
    localizations: [String: LocalizationInput]
  ) {
    self.key = key
    self.comment = comment
    self.extractionState = extractionState
    self.shouldTranslate = shouldTranslate
    self.localizations = localizations
  }
}

public struct CatalogKeyDescriptor: Codable, Equatable {
  public var key: String
  public var extractionState: String
  public var shouldTranslate: Bool
  public var locales: [String]

  public init(key: String, extractionState: String, shouldTranslate: Bool, locales: [String]) {
    self.key = key
    self.extractionState = extractionState
    self.shouldTranslate = shouldTranslate
    self.locales = locales
  }
}

public struct InspectResult: Codable, Equatable {
  public var sourceLanguage: String
  public var locales: [String]
  public var keyCount: Int
  public var manualKeyCount: Int
  public var autoKeyCount: Int
  public var translatableKeyCount: Int
  public var keys: [CatalogKeyDescriptor]

  public init(
    sourceLanguage: String,
    locales: [String],
    keyCount: Int,
    manualKeyCount: Int,
    autoKeyCount: Int,
    translatableKeyCount: Int,
    keys: [CatalogKeyDescriptor]
  ) {
    self.sourceLanguage = sourceLanguage
    self.locales = locales
    self.keyCount = keyCount
    self.manualKeyCount = manualKeyCount
    self.autoKeyCount = autoKeyCount
    self.translatableKeyCount = translatableKeyCount
    self.keys = keys
  }
}

public struct LocalesResult: Codable, Equatable {
  public var sourceLanguage: String
  public var locales: [String]

  public init(sourceLanguage: String, locales: [String]) {
    self.sourceLanguage = sourceLanguage
    self.locales = locales
  }
}

public enum FindField: String, Codable, Equatable {
  case key
  case string
  case comment
}

public enum FindMatchMode: String, Codable, Equatable {
  case exact
  case contains
  case prefix
  case suffix
  case regex
}

public struct FindQuery: Equatable {
  public var field: FindField
  public var value: String
  public var locale: String?
  public var match: FindMatchMode

  public init(field: FindField, value: String, locale: String? = nil, match: FindMatchMode = .exact) {
    self.field = field
    self.value = value
    self.locale = locale
    self.match = match
  }
}

public struct FindMatchedValue: Codable, Equatable {
  public var field: FindField
  public var locale: String?
  public var value: String?
  public var match: FindMatchMode

  public init(field: FindField, locale: String? = nil, value: String? = nil, match: FindMatchMode) {
    self.field = field
    self.locale = locale
    self.value = value
    self.match = match
  }
}

public struct FindResultEntry: Codable, Equatable {
  public var key: String
  public var extractionState: String
  public var comment: String?
  public var matched: [FindMatchedValue]

  public init(key: String, extractionState: String, comment: String? = nil, matched: [FindMatchedValue]) {
    self.key = key
    self.extractionState = extractionState
    self.comment = comment
    self.matched = matched
  }
}

public struct ShowLocalizationValue: Codable, Equatable {
  public var state: String
  public var value: String

  public init(state: String, value: String) {
    self.state = state
    self.value = value
  }
}

public struct ShowResult: Codable, Equatable {
  public var key: String
  public var extractionState: String
  public var comment: String?
  public var shouldTranslate: Bool
  public var localizations: [String: [ShowLocalizationValue]]

  public init(
    key: String,
    extractionState: String,
    comment: String? = nil,
    shouldTranslate: Bool,
    localizations: [String: [ShowLocalizationValue]]
  ) {
    self.key = key
    self.extractionState = extractionState
    self.comment = comment
    self.shouldTranslate = shouldTranslate
    self.localizations = localizations
  }
}

public enum IssueSeverity: String, Codable {
  case error
  case warning
}

public struct ValidationIssue: Codable, Equatable {
  public var severity: IssueSeverity
  public var code: String
  public var key: String?
  public var locale: String?
  public var message: String

  public init(
    severity: IssueSeverity,
    code: String,
    key: String? = nil,
    locale: String? = nil,
    message: String
  ) {
    self.severity = severity
    self.code = code
    self.key = key
    self.locale = locale
    self.message = message
  }
}

public struct ValidationResult: Codable, Equatable {
  public var sourceLanguage: String
  public var requiredLocales: [String]
  public var errors: [ValidationIssue]
  public var warnings: [ValidationIssue]

  public var isSuccess: Bool {
    errors.isEmpty
  }

  public init(
    sourceLanguage: String,
    requiredLocales: [String],
    errors: [ValidationIssue],
    warnings: [ValidationIssue]
  ) {
    self.sourceLanguage = sourceLanguage
    self.requiredLocales = requiredLocales
    self.errors = errors
    self.warnings = warnings
  }
}

public struct MutationSummary: Codable, Equatable {
  public var added: [String]
  public var updated: [String]
  public var removed: [String]
  public var localesAdded: [String]
  public var localesRemoved: [String]

  public init(
    added: [String] = [],
    updated: [String] = [],
    removed: [String] = [],
    localesAdded: [String] = [],
    localesRemoved: [String] = []
  ) {
    self.added = added
    self.updated = updated
    self.removed = removed
    self.localesAdded = localesAdded
    self.localesRemoved = localesRemoved
  }

  public var isEmpty: Bool {
    added.isEmpty && updated.isEmpty && removed.isEmpty && localesAdded.isEmpty && localesRemoved.isEmpty
  }

  public mutating func recordAdded(_ key: String) {
    appendUnique(key, to: &added)
  }

  public mutating func recordUpdated(_ key: String) {
    appendUnique(key, to: &updated)
  }

  public mutating func recordRemoved(_ key: String) {
    appendUnique(key, to: &removed)
  }

  public mutating func recordLocaleAdded(_ locale: String) {
    appendUnique(locale, to: &localesAdded)
  }

  public mutating func recordLocaleRemoved(_ locale: String) {
    appendUnique(locale, to: &localesRemoved)
  }

  public mutating func merge(_ other: MutationSummary) {
    other.added.forEach { recordAdded($0) }
    other.updated.forEach { recordUpdated($0) }
    other.removed.forEach { recordRemoved($0) }
    other.localesAdded.forEach { recordLocaleAdded($0) }
    other.localesRemoved.forEach { recordLocaleRemoved($0) }
  }

  public mutating func finalize() {
    added.sort()
    updated.sort()
    removed.sort()
    localesAdded.sort()
    localesRemoved.sort()
  }

  private func appendUnique(_ value: String, to array: inout [String]) {
    if !array.contains(value) {
      array.append(value)
    }
  }
}

public struct MutationResult: Codable, Equatable {
  public var changed: Bool
  public var dryRun: Bool
  public var summary: MutationSummary
  public var validation: ValidationResult

  public var isSuccess: Bool {
    validation.isSuccess
  }

  public init(
    changed: Bool,
    dryRun: Bool,
    summary: MutationSummary,
    validation: ValidationResult
  ) {
    self.changed = changed
    self.dryRun = dryRun
    self.summary = summary
    self.validation = validation
  }
}
