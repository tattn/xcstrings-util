# xcstrings-util

`xcstrings-util` is a command-line tool for inspecting and editing Xcode string catalogs (`.xcstrings`).

It is designed for direct, scriptable use from tools such as Codex and Claude Code:

- one `.xcstrings` file per invocation
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
xcstrings-util locales <path> [--json]
xcstrings-util inspect <path> [--json]
xcstrings-util find <path> (--key <key> | --string <text> | --comment <text>) [--locale <locale>] [--match exact|contains|prefix|suffix|regex] [--json]
xcstrings-util show <path> --key <key> [--json]
xcstrings-util validate <path> [--strict] [--required-locales en,ja] [--json]
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

Find a key:

```bash
xcstrings-util find Localizable.xcstrings --key add_task --json
```

Show a single entry:

```bash
xcstrings-util show Localizable.xcstrings --key add_task --json
```

Validate a catalog:

```bash
xcstrings-util validate Localizable.xcstrings --strict --json
```

Upsert translations from stdin:

```bash
xcstrings-util upsert Localizable.xcstrings --key add_task --comment "Add button label" --json <<'EOS'
{
  "en": "Add task",
  "ja": "タスクを追加"
}
EOS
```

Comment-only update:

```bash
xcstrings-util upsert Localizable.xcstrings --key add_task --comment "Add button label" --json
```

## Notes

- Mutation commands update only `manual` entries.
- Auto-extracted entries are treated as read-only.
- Mutation commands write changes unless `--dry-run` is present.
- `upsert` reads JSON from stdin when `--input` is not provided.
