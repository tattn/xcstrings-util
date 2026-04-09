#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOS'
Usage:
  generate_homebrew_formula.sh \
    --arm64-url <archive-url> \
    --arm64-sha256 <sha256> \
    --x86_64-url <archive-url> \
    --x86_64-sha256 <sha256> \
    --homepage <homepage-url> \
    --version <version> \
    [--license <spdx-license>] \
    [--desc <description>] \
    [--output <formula-path>]

Example:
  ./scripts/generate_homebrew_formula.sh \
    --arm64-url https://github.com/USER/xcstrings-util/releases/download/v0.1.0/xcstrings-util-0.1.0-macos-arm64.tar.gz \
    --arm64-sha256 abcdef... \
    --x86_64-url https://github.com/USER/xcstrings-util/releases/download/v0.1.0/xcstrings-util-0.1.0-macos-x86_64.tar.gz \
    --x86_64-sha256 123456... \
    --homepage https://github.com/USER/xcstrings-util \
    --version 0.1.0 \
    --license MIT
EOS
}

desc='Agent-friendly CLI for Xcode string catalogs'
formula_path='Formula/xcstrings-util.rb'
arm64_sha256=''
arm64_url=''
homepage=''
license=''
version=''
x86_64_sha256=''
x86_64_url=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm64-url)
      arm64_url="${2:-}"
      shift 2
      ;;
    --arm64-sha256)
      arm64_sha256="${2:-}"
      shift 2
      ;;
    --x86_64-url)
      x86_64_url="${2:-}"
      shift 2
      ;;
    --x86_64-sha256)
      x86_64_sha256="${2:-}"
      shift 2
      ;;
    --homepage)
      homepage="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --license)
      license="${2:-}"
      shift 2
      ;;
    --desc)
      desc="${2:-}"
      shift 2
      ;;
    --output)
      formula_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$arm64_url" || -z "$arm64_sha256" || -z "$x86_64_url" || -z "$x86_64_sha256" || -z "$homepage" || -z "$version" ]]; then
  echo "--arm64-url, --arm64-sha256, --x86_64-url, --x86_64-sha256, --homepage, and --version are required." >&2
  usage >&2
  exit 2
fi

formula_dir="$(dirname "$formula_path")"
mkdir -p "$formula_dir"

license_line=''
if [[ -n "$license" ]]; then
  license_line="  license \"${license}\""
fi

cat >"$formula_path" <<EOS
class XcstringsUtil < Formula
  desc "${desc}"
  homepage "${homepage}"
  version "${version}"
${license_line}

  on_macos do
    on_arm do
      url "${arm64_url}"
      sha256 "${arm64_sha256}"
    end

    on_intel do
      url "${x86_64_url}"
      sha256 "${x86_64_sha256}"
    end
  end

  def install
    bin.install "xcstrings-util"
  end

  test do
    sample = testpath/"Sample.xcstrings"
    sample.write <<~JSON
      {
        "sourceLanguage" : "en",
        "strings" : {
          "title" : {
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
    JSON

    output = shell_output("#{bin}/xcstrings-util locales #{sample} --json")
    assert_match "\"sourceLanguage\" : \"en\"", output
    assert_match "\"locales\" : [", output
    assert_match "\"en\"", output
  end
end
EOS

echo "Wrote ${formula_path}"
