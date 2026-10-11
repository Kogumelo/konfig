# Archived idea: a multi-format Rust library for lossless config editing

**Status:** archived on 2026-10-10. No code was written.
**Decision:** Konfig continues as a **multi-format visual app** (Swift). The Rust
library does not go ahead.
**Origin:** the "Rust core" block in Sitroom: research mission `941f79c0` and
experiment mission `c12e0096`. The experiment was cancelled before it started.

This document keeps the idea, the research and the experiment design so that
someone can pick it up again if a new fact comes up, without retracing the path.

## The idea

An open-source library written entirely in Rust that reads, edits and writes
several configuration formats (TOML, JSON/JSONC and, later, YAML, INI and .env)
**without losing comments or formatting**. On save, it replaces only the bytes of the
changed values, which is the same guarantee as Konfig's `Sources/ConfCore` core.

The premise had two halves:

1. there is no pure-Rust, multi-format, lossless library (and in particular
   there is no lossless JSON/JSONC editing in Rust);
2. there are people who want one.

## Why it was archived

The research (mission `941f79c0`, data gathered on 2026-10-10) knocked down the
first half:

- **[edikt](https://github.com/jhheider/edikt)** is exactly the product we had in mind:
  pure Rust, 7 formats (JSONC/JSON5, TOML, YAML, INI, KDL, .env/.properties,
  frontmatter), "byte for byte" editing, released in July 2026. Internally it uses
  `toml_edit` and `kdl-rs`.
- **[jsonc-parser](https://crates.io/crates/jsonc-parser)** (from dprint), with the
  `cst` feature, already edits JSONC losslessly ("keeps every comment and every piece of
  whitespace"). It has 11.3 million downloads and Deno uses it to edit
  `deno.json` in `deno add` and `deno bump-version`. The "JSON gap" does not exist.
- **[toml_edit](https://crates.io/crates/toml_edit)** has solved TOML for years (892
  million downloads).

The second half stands, with a caveat: the pain of losing comments is real and
long-standing (yq [#515](https://github.com/mikefarah/yq/issues/515) with 156 👍, dasel
[#178](https://github.com/TomWright/dasel/issues/178), jq
[#1571](https://github.com/jqlang/jq/issues/1571)). But the requests are for
command-line tools, not for a Rust library. The existing multi-format
libraries have almost no adoption: edikt with 336 downloads and 3★,
fig with 3.4 thousand downloads and 11★, each maintained by a single person.

A prototype with TOML and JSON would repeat what `toml_edit` and `jsonc-parser` already
do, and what edikt already combines on top of them.

On the other hand, the research **found no multi-format visual app** that writes
only the changed bytes. The app's competitors handle a single format each: Power TOML
Editor, JSON Editor (VDT Labs) and Tommy Flyleaf (TOML, Rust + egui). Hence the decision
to invest in the app.

## Competitive landscape (2026-10-10)

The "Preserves bytes?" column repeats what each project claims: **none of them was
tested**.

| Name | Language | Formats | Preserves bytes? | Downloads (crates.io) | Latest version | License |
|---|---|---|---|---|---|---|
| [fig](https://crates.io/crates/fig) / fig-sys | Zig, with a Rust binding | JSON/JSONC/JSON5, YAML, TOML, INI, .env, .properties, plist, NestedText, ZON | Claims so | 3,459 / 3,246 | v5.2.0, 2026-10-03 | MIT OR Apache-2.0 |
| [edikt](https://crates.io/crates/edikt) | Pure Rust | JSONC/JSON5, TOML, YAML, INI, KDL, .env/.properties, frontmatter | Claims so | 336 (edikt-core: 14,538) | v0.8.1, 2026-09-29 | MIT OR Apache-2.0 |
| [patchloom](https://crates.io/crates/patchloom) | Rust | JSON, YAML, TOML (aimed at AI agents) | Claims to preserve comments; no byte-for-byte guarantee | 1,505 | v0.37.1, 2026-10-08 | MIT OR Apache-2.0 |
| [jsonc-parser](https://crates.io/crates/jsonc-parser) (`cst`) | Rust | JSON/JSONC | Yes | 11,300,339 | 0.34.0, 2026-09-27 | MIT |
| [json-five](https://crates.io/crates/json-five) | Rust | JSON5 | Claims "round-trip"; not verified | 1,248,735 | 0.3.1, 2026-01-08 | MIT |
| [toml_edit](https://crates.io/crates/toml_edit) | Rust | TOML | Yes | 892,019,968 | 0.25.17, 2026-10-09 | MIT OR Apache-2.0 |
| [yaml-edit](https://crates.io/crates/yaml-edit) | Rust | YAML | Claims "lossless" | 152,999 | 0.3.2, 2026-09-17 | Apache-2.0 |
| [yamlpatch](https://crates.io/crates/yamlpatch) | Rust | YAML | Claims to preserve comments and formatting | 354,622 | 1.30.1, 2026-09-09 | MIT |
| ini-roundtrip / ini-preserve / ini-edit | Rust | INI | Claim so | 46,458 / 1,604 / 253 | 2025-12 to 2026-10 | MIT |
| [envq](https://crates.io/crates/envq) | Rust | .env | Claims "byte-preserving" | 479 | 0.1.4, 2026-09-20 | BSD-3-Clause |
| [Augeas](https://github.com/hercules-team/augeas) | C | `/etc` formats | Yes, but with open TOML bugs (#715, #699) | — | push on 2026-09-29 | LGPL-2.1 |
| dasel / yq | Go | several | No guarantee | — | 2026 | MIT |

About **fig**: the Rust binding is complete (edit, insert, remove, rename,
move keys, work with comments), but it depends on a native Zig library
prebuilt only for macOS arm64, Linux x64/arm64 (gnu), Windows x64, wasm32 and
iOS. Intel Macs and Linux musl are left out.

Full research report: card `941f79c0` in Sitroom
(`~/.sitroom/tasks/closed/941f79c0.json`).

## The planned experiment (mission `c12e0096`)

It was a one-afternoon experiment, to decide whether the idea would continue. It is
recorded here in case it is picked up again.

- **Where:** a new local folder, `~/Kogumelo/Ferramentas/konfig-rs`, with `git init`.
  Nothing on GitHub or crates.io without the operator's approval. The Swift project
  would not be touched.
- **Minimal API, the same for both formats:** open from bytes; read a
  value by path (`server.port`, `items[2].name`); change the value at an
  existing path; save, returning the bytes.
- **TOML:** on top of `toml_edit`, without rewriting the parser.
- **JSON/JSONC:** its own lossless parser (`//` and `/* */` comments, optional trailing
  comma, whitespace and order preserved; when a value changes, only its
  bytes change).
- **Tests:**
  - toml-test (copy Konfig's `Tests/ConfCoreTests/Fixtures`): valid cases accepted,
    invalid ones rejected, and open/save without changes identical byte for byte;
  - JSON: cases with comments, CRLF, BOM, Unicode escapes, large numbers and
    decimals, plus the [JSONTestSuite](https://github.com/nst/JSONTestSuite);
  - the same files and edits through the `fig` package, recording where each one
    preserves better or worse.
- **Success criteria (all three together):** the whole toml-test passing; JSONC
  preserved byte for byte after editing a value in every case; and **a
  concrete, measured advantage over fig** (a case where fig loses bytes and
  this does not, or API, size, compiling to WebAssembly). Without a measured advantage,
  archive.
- **Out of scope:** YAML, INI, .env, a Swift bridge, a command-line tool,
  inserting or removing keys, publishing.

Given what the research showed, the experiment should compare against **edikt and
jsonc-parser**, not just against fig. Writing a custom JSONC parser in Rust makes no
sense: `jsonc-parser` already does that.

## What would bring the idea back

Reopen only with a new fact, for example:

- a comparative test showing that edikt and fig **lose bytes** in edge cases
  (the toml-test suite, the JSONTestSuite, files with CRLF, BOM, escapes) and that
  `toml_edit` + `jsonc-parser` do not handle those cases;
- edikt or fig being abandoned while people are using them;
- the Konfig app needing to run outside the Mac (Linux, Windows, the browser via
  WebAssembly), which would make a portable Rust core useful for the app itself;
- explicit requests for such a library (issues, discussions), which the
  research did not find.

The advantage Konfig already has and that no competitor publishes is
**verified conformance against official suites** (toml-test and JSONTestSuite). If
the idea comes back, that is where it would stand out, not by being the first.

## References

All links cited in the report of mission `941f79c0`, consulted on
2026-10-10.

**fig**
- Packages: <https://crates.io/crates/fig>, <https://crates.io/crates/fig-sys>,
  <https://docs.rs/crate/fig>; download data: <https://crates.io/api/v1/crates/fig>
- Repository and README ("Every other byte is preserved"): <https://github.com/diaryx-org/fig>
- Rust binding API: <https://github.com/diaryx-org/fig/blob/main/bindings/rust/fig/src/editor.rs>
- Prebuilt targets: <https://github.com/diaryx-org/fig/blob/main/bindings/rust/fig-sys/Cargo.toml>
- The only issue ("Nightly fuzz run failed"): <https://github.com/diaryx-org/fig/issues/1>
- Announcement: <https://ziggit.dev/t/fig-convert-yaml-toml-jsonc-preserve-comments/16555>

**Other libraries**
- edikt: <https://crates.io/crates/edikt>, <https://github.com/jhheider/edikt>,
  <https://crates.io/crates/edikt-yaml>; what pulls in edikt-core: <https://crates.io/crates/asimov-cli>
- patchloom: <https://crates.io/crates/patchloom>, <https://github.com/patchloom/patchloom>
- jsonc-parser: <https://crates.io/crates/jsonc-parser>,
  <https://docs.rs/jsonc-parser/latest/jsonc_parser/cst/index.html>,
  <https://docs.rs/jsonc-parser/latest/jsonc_parser/cst/struct.CstObject.html>
- Use in Deno: <https://github.com/denoland/deno/blob/main/cli/tools/pm/mod.rs>,
  <https://github.com/denoland/deno/blob/main/cli/tools/bump_version.rs>
- JSON5: <https://crates.io/crates/json-five>, <https://crates.io/crates/json5format>,
  <https://crates.io/crates/monochromatic-jsonc-edit>
- TOML: <https://crates.io/crates/toml_edit>
- YAML: <https://crates.io/crates/yaml-edit>, <https://crates.io/crates/yamlpatch>
- INI: <https://crates.io/crates/ini-roundtrip>, <https://crates.io/crates/ini-preserve>,
  <https://crates.io/crates/ini-edit>
- .env: <https://crates.io/crates/envq>
- Augeas: <https://github.com/hercules-team/augeas>,
  <https://github.com/hercules-team/augeas/issues/715>,
  <https://github.com/hercules-team/augeas/issues/699>
- dasel and yq: <https://github.com/TomWright/dasel>, <https://github.com/mikefarah/yq>

**Demand signals**
- yq: <https://github.com/mikefarah/yq/issues/515>, <https://github.com/mikefarah/yq/issues/19>,
  <https://github.com/mikefarah/yq/issues/442>, <https://github.com/mikefarah/yq/issues/2592>,
  <https://github.com/mikefarah/yq/issues/2536>
- dasel: <https://github.com/TomWright/dasel/issues/178>
- jq: <https://github.com/jqlang/jq/issues/1571>
- Renovate: <https://github.com/renovatebot/renovate/issues/12260>,
  <https://github.com/renovatebot/renovate/pull/38646>
- Zed: <https://github.com/zed-industries/zed/issues/40270>
- Weekly downloads outside Rust: <https://api.npmjs.org/downloads/point/last-week/jsonc-parser>,
  <https://pypistats.org/api/packages/tomlkit/recent> (comment-json and ruamel.yaml
  came from the same APIs)
- Hacker News, "Show HN: Yqr": <https://news.ycombinator.com/item?id=48871455>
- Blog post "Respectful" YAML Patching in Rust: <https://verrchu.github.io/blog/2-respectful-yaml-patching-in-rust/>

**Visual apps**
- Power TOML Editor: <https://apps.apple.com/us/app/id1587914025>
  (version date: <https://www.iphoneaddict.fr/apps/mac/developpeurs/power-toml-editor.html>)
- JSON Editor (VDT Labs): <https://apps.apple.com/us/app/json-editor/id567740330?mt=12>
- Tommy Flyleaf: <https://github.com/excelano/flyleaf>
- Power YAML Editor: <https://apps.apple.com/us/app/id1565766176>
- Power JSON Editor: <https://apps.apple.com/app/power-json-editor/id499768540>

**Test suites**
- toml-test: <https://github.com/toml-lang/toml-test>
- JSONTestSuite: <https://github.com/nst/JSONTestSuite>
