# xcstrings-util

`xcstrings-util` is a command-line tool for inspecting and editing Xcode string catalogs (`.xcstrings`).

It is designed for direct, scriptable use from tools such as Codex and Claude Code:

- stable JSON output with `--json`
- direct mutation by default
- `--dry-run` for previewing changes
- automatic validation after mutation commands

## Installation

Install with Homebrew:

```bash
brew tap tattn/xcstrings-util
brew install tattn/xcstrings-util/xcstrings-util
```

If you already added the tap and only want to upgrade:

```bash
brew update
brew upgrade xcstrings-util
```

## Commands

```bash
xcstrings-util locales [<path>] [--json]
xcstrings-util inspect [<path>] [--json]
xcstrings-util find [<path>] (--key <key> | --string <text> | --comment <text>) [--locale <locale>] [--match exact|contains|prefix|suffix|regex] [--json]
xcstrings-util show [<path>] --key <key> [--json]
xcstrings-util validate [<path>] [--strict] [--required-locales en,ja] [--locales-from <path|dir>] [--json]
xcstrings-util upsert <path> --key <key> [--comment <text>] [--input <file>] [--dry-run] [--json]
xcstrings-util remove <path> --key <key> [--dry-run] [--json]
xcstrings-util locale add <path> --locale <locale> [--copy-from <locale>] [--state new|needs_review|translated] [--dry-run] [--json]
xcstrings-util locale remove <path> --locale <locale> [--dry-run] [--json]
```

## Examples

List locales:

```bash
xcstrings-util locales Localizable.xcstrings --json
```

Find a key across all catalogs:

```bash
xcstrings-util find --key add_task --json
```

Show a key (searches all catalogs when path is omitted):

```bash
xcstrings-util show --key add_task --json
```

Validate all catalogs in the current directory:

```bash
xcstrings-util validate
```

Validate a single catalog:

```bash
xcstrings-util validate Localizable.xcstrings --strict --json
```

Validate with locales detected from other files (useful for catalogs without manual keys, e.g. AppShortcuts):

```bash
xcstrings-util validate AppShortcuts.xcstrings --locales-from ./Sources --json
```

Upsert translations from stdin:

```bash
xcstrings-util upsert Localizable.xcstrings --key add_task --comment "Add button label" --json <<'EOS'
{
  "en": "Add Task",
  "ja": "タスクを追加"
}
EOS
```

Comment-only update:

```bash
xcstrings-util upsert Localizable.xcstrings --key add_task --comment "Add button label" --json
```

## Notes

- Supports both `stringUnit` and `stringSet` (App Shortcuts phrases) formats.
- Mutation commands update only `manual` entries.
- Auto-extracted entries are treated as read-only.
- Mutation commands write changes unless `--dry-run` is present.
- `upsert` reads JSON from stdin when `--input` is not provided.
- `--locales-from` accepts a file or directory; when a directory is given, all `.xcstrings` files within are scanned for locale detection.
- When path is omitted, read commands and validate scan the current directory for `.xcstrings` files.
