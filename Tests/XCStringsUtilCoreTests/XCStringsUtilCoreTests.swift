import Foundation
import Testing
@testable import XCStringsUtilCore

@Suite("XCStringsUtilCore")
struct XCStringsUtilCoreTests {
  @Test("locales returns source language and detected locales")
  func localesReturnsDetectedLocales() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = catalog.locales()

    #expect(result.sourceLanguage == "en")
    #expect(result.locales == ["en", "ja"])
  }

  @Test("find matches key search with actual prefix match kind")
  func findMatchesKey() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = try catalog.find(
      FindQuery(field: .key, value: "tit", match: .contains)
    )

    #expect(result.count == 1)
    #expect(result.first?.key == "title")
    #expect(result.first?.extractionState == "manual")
    #expect(result.first?.comment == "Screen title")
    #expect(result.first?.matched == [
      FindMatchedValue(field: .key, match: .prefix)
    ])
  }

  @Test("find matches string in a specific locale")
  func findMatchesLocalizedString() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = try catalog.find(
      FindQuery(field: .string, value: "Title", locale: "en", match: .contains)
    )

    #expect(result.count == 1)
    #expect(result.first?.key == "title")
    #expect(result.first?.matched == [
      FindMatchedValue(field: .string, locale: "en", value: "Title", match: .exact)
    ])
  }

  @Test("find matches comments and includes matched comment value")
  func findMatchesComment() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = try catalog.find(
      FindQuery(field: .comment, value: "Screen", match: .contains)
    )

    #expect(result.count == 1)
    #expect(result.first?.key == "title")
    #expect(result.first?.matched == [
      FindMatchedValue(field: .comment, value: "Screen title", match: .prefix)
    ])
  }

  @Test("show returns key details and localized values")
  func showReturnsKeyDetails() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = try catalog.show(key: "title")

    #expect(result.key == "title")
    #expect(result.extractionState == "manual")
    #expect(result.comment == "Screen title")
    #expect(result.shouldTranslate == true)
    #expect(result.localizations == [
      "en": [ShowLocalizationValue(state: "translated", value: "Title")]
    ])
  }

  @Test("validate detects missing locales and placeholder mismatches")
  func validateDetectsErrors() throws {
    let catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let result = catalog.validate(requiredLocales: ["en", "ja"], strict: true)
    let hasPlaceholderMismatch = result.errors.contains { issue in
      issue.code == "placeholder_mismatch"
        && issue.key == "task_count %lld"
        && issue.locale == "ja"
    }
    let hasMissingTranslation = result.errors.contains { issue in
      issue.code == "missing_translation"
        && issue.key == "title"
        && issue.locale == "ja"
    }

    #expect(result.isSuccess == false)
    #expect(hasPlaceholderMismatch)
    #expect(hasMissingTranslation)
  }

  @Test("validate allows reordered numbered placeholders")
  func validateAllowsReorderedNumberedPlaceholders() throws {
    let catalog = try XCStringsCatalog(data: Data(numberedPlaceholderCatalog.utf8))
    let result = catalog.validate(requiredLocales: ["en", "ja"], strict: true)
    let hasPlaceholderMismatch = result.errors.contains { issue in
      issue.code == "placeholder_mismatch" && issue.key == "trial_description"
    }

    #expect(hasPlaceholderMismatch == false)
  }

  @Test("upsert adds a manual key and keeps catalog valid")
  func upsertAddsKey() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))
    let input = EntryInput(
      key: "new_key",
      localizations: [
        "en": LocalizationInput(value: "New key"),
        "ja": LocalizationInput(value: "新しいキー"),
      ]
    )

    let summary = try catalog.upsert(input)
    let inspect = catalog.inspect()
    let validation = catalog.validate(requiredLocales: ["en", "ja"])
    let keepsExistingValidationError = validation.errors.contains { issue in
      issue.key == "task_count %lld"
    }

    #expect(summary.added == ["new_key"])
    #expect(inspect.keys.contains(where: { $0.key == "new_key" }))
    #expect(keepsExistingValidationError)
  }

  @Test("remove rejects non-manual keys")
  func removeRejectsNonManualKey() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))

    do {
      _ = try catalog.remove(key: "auto_key")
      Issue.record("Expected remove to throw for a non-manual key.")
    } catch let error as XCStringsCatalogError {
      #expect(error.errorDescription == XCStringsCatalogError.nonManualKey("auto_key").errorDescription)
    }
  }

  @Test("locale add and remove only touch manual entries")
  func localeAddAndRemove() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))

    let addSummary = try catalog.addLocale("fr", copyFrom: "en", state: "needs_review")
    #expect(addSummary.localesAdded == ["fr"])

    let inspectAfterAdd = catalog.inspect()
    let titleLocales = inspectAfterAdd.keys.first(where: { $0.key == "title" })?.locales ?? []
    let autoLocales = inspectAfterAdd.keys.first(where: { $0.key == "auto_key" })?.locales ?? []
    #expect(titleLocales.contains("fr"))
    #expect(autoLocales.contains("fr") == false)

    let removeSummary = try catalog.removeLocale("fr")
    #expect(removeSummary.localesRemoved == ["fr"])

    let inspectAfterRemove = catalog.inspect()
    let localesAfterRemove = inspectAfterRemove.keys.first(where: { $0.key == "title" })?.locales ?? []
    #expect(localesAfterRemove.contains("fr") == false)
  }

  @Test("upsert stores and removes entry comments")
  func upsertStoresAndRemovesComment() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))

    _ = try catalog.upsert(
      EntryInput(
        key: "title",
        comment: "Navigation title",
        localizations: [
          "en": LocalizationInput(value: "Title"),
          "ja": LocalizationInput(value: "タイトル"),
        ]
      )
    )
    let withComment = try String(decoding: catalog.formattedData(), as: UTF8.self)
    #expect(withComment.contains(#""comment" : "Navigation title""#))

    _ = try catalog.upsert(
      EntryInput(
        key: "title",
        comment: "",
        localizations: [
          "en": LocalizationInput(value: "Title"),
          "ja": LocalizationInput(value: "タイトル"),
        ]
      )
    )
    let withoutComment = try String(decoding: catalog.formattedData(), as: UTF8.self)
    #expect(withoutComment.contains(#""comment" : "Navigation title""#) == false)
  }

  @Test("upsert allows comment-only updates on existing keys")
  func upsertCommentOnlyUpdate() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))

    let summary = try catalog.upsert(
      EntryInput(
        key: "title",
        comment: "Updated title comment",
        localizations: [:]
      )
    )

    let formatted = try String(decoding: catalog.formattedData(), as: UTF8.self)
    #expect(summary.updated == ["title"])
    #expect(formatted.contains(#""comment" : "Updated title comment""#))
    #expect(formatted.contains(#""value" : "Title""#))
  }

  @Test("upsert rejects new keys without localizations")
  func upsertRejectsEmptyNewEntry() throws {
    var catalog = try XCStringsCatalog(data: Data(sampleCatalog.utf8))

    do {
      _ = try catalog.upsert(
        EntryInput(
          key: "comment_only_new_key",
          comment: "Translator note",
          localizations: [:]
        )
      )
      Issue.record("Expected upsert to reject creating a new key without localizations.")
    } catch let error as XCStringsCatalogError {
      #expect(
        error.errorDescription
          == XCStringsCatalogError.invalidInput("Adding a new key requires at least one localization.").errorDescription
      )
    }
  }
}

private let sampleCatalog = #"""
{
  "sourceLanguage" : "en",
  "strings" : {
    "" : {
      "extractionState" : "extracted",
      "localizations" : {
      }
    },
    "auto_key" : {
      "extractionState" : "extracted",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Auto"
          }
        }
      }
    },
    "task_count %lld" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "%lld tasks"
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "タスク"
          }
        }
      }
    },
    "title" : {
      "comment" : "Screen title",
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Title"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
"""#

private let numberedPlaceholderCatalog = #"""
{
  "sourceLanguage" : "en",
  "strings" : {
    "trial_description" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "%2$lld days free, then %1$@"
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "%1$@、その後%2$lld日間無料"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
"""#
