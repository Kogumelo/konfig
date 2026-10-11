# Konfig

**English** · [Português](README.pt-BR.md)

<img src="icon/konfig.svg" width="128" alt="Konfig icon: a switch turned on with the letter K">

A native Mac editor for configuration files: **TOML**, **JSON**, **JSONC**
(JSON with comments and trailing commas, as in `tsconfig.json` and `.vscode/settings.json`),
**JSON5** (unquoted keys, single quotes, hexadecimal, `Infinity`…), **.env**
(`KEY=value` environment variables), **INI** (`php.ini`, `.editorconfig`, `desktop.ini`…) and **YAML**
(the subset used by configuration files: docker-compose, GitHub Actions, Kubernetes, `pubspec.yaml`, OpenAPI).
It opens the file from the Finder (double-click or "Open With"), shows each value in a
field of the right type and, on save, replaces **only the bytes of the values that
changed**: comments, order, whitespace, quotes, escapes, number style, CRLF
and BOM stay exactly as they were.

Swift/AppKit + SwiftUI, no dependencies. The parsers are its own (they need to know
where each value sits in the text): the TOML 1.0 parser passes the official
[toml-test](https://github.com/toml-lang/toml-test) suite; the JSON parser passes the
[JSONTestSuite](https://github.com/nst/JSONTestSuite) (every `y_` accepted, every
`n_` rejected; the `i_` cases are under [Limitations](#json-jsonc-and-json5)); the JSON5
parser passes the official [json5-tests](https://github.com/json5/json5-tests) suite (all 83
valid cases accepted and all 31 invalid ones rejected, none skipped). JSONC has no
official suite: there are hand-written files in `Tests/ConfCoreTests/Fixtures/jsonc/`.
The `.env` parser follows the rules of `dotenv` (Node/Ruby), spelled out in [.env rules](#env-rules).
INI has no standard: Konfig accepts one fixed dialect, described in [INI dialect](#ini-dialect) and
tested with hand-written files, with `.editorconfig` files from the EditorConfig project and with an
excerpt of PHP's `php.ini-production` (`Tests/ConfCoreTests/Fixtures/ini/`).
The YAML parser is tested against the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
(the 192 cases inside the [accepted subset](#yaml) read with the expected values, the 94 invalid
cases rejected, and the 116 that use what is left out either rejected or read without differences).

Part of Kogumelo's family of tools, whose names start with K
(see also Katraca). It used to be called `km-toml` and then `km-conf`: the first name changed
because the plan was to edit several formats; the second, on 2026-10-11, when the tools
swapped the `km-` prefix for the initial K. Today: TOML, JSON,
JSONC, JSON5, .env, INI and YAML (see [Next formats](#next-formats)).

Code, comments and identifiers are in English; the user interface is in English and
Portuguese (see [Localization](#localization)).

## Building

```sh
./build.sh
```

Produces `Konfig.app` in this folder, signed locally (`codesign --sign -`).
Requires Xcode (Swift 6) and runs on macOS 14 or later. The release build
takes a few minutes.

The icon ships ready-made in `icon/Konfig.icns`; the source drawing is `icon/konfig.svg`.
After changing the drawing, regenerate the `.icns` with `./icon/make-icon.sh`.

Core tests (parsers, writing, fields):

```sh
swift test
```

The core (`ConfCore`) also builds and passes its tests on Linux; there
`Package.swift` leaves out the app, which depends on AppKit:

```sh
docker run --rm -v "$PWD":/src:ro swift:6.0 \
  bash -c 'cp -r /src /tmp/w && cd /tmp/w && rm -rf .build && swift test'
```

## Usage

```sh
open -a "$PWD/Konfig.app" examples/config.toml
open -a "$PWD/Konfig.app" examples/config.json
open -a "$PWD/Konfig.app" examples/config.jsonc
open -a "$PWD/Konfig.app" examples/settings.jsonc
open -a "$PWD/Konfig.app" examples/config.json5
open -a "$PWD/Konfig.app" examples/.env
open -a "$PWD/Konfig.app" examples/config.ini
open -a "$PWD/Konfig.app" examples/config.yaml
# or
open Konfig.app --args examples/config.toml
```

The format comes from the file name: extension `.toml`, `.json`, `.jsonc`, `.json5`, `.ini`, `.yaml` or `.yml`
(also the file named `.editorconfig`, which is INI); and `.env`
for the file named exactly `.env`, for `.env.anything` (`.env.local`,
`.env.production`) and for `anything.env` (`production.env`). The name counts for more
than the type macOS gives the file: for `.env` the system reports an empty extension and
the generic type `public.data`, and for `.env.local`, the extension `local` (a test
checks this).

**A `.json` with a comment or a trailing comma is opened as JSONC**, with the discreet
notice "JSON with comments" at the bottom of the sidebar, instead of being rejected. The
reason: many configuration files with a `.json` extension are, in practice, JSONC
— VS Code's `settings.json` and `launch.json`, `tsconfig.json`,
`devcontainer.json`, `.eslintrc.json`. Rejecting them would make the app useless precisely
for them, and the file's owner has already chosen the dialect (the program that reads it accepts
comments). The notice exists because the reverse does not hold: not every program that reads
JSON accepts comments, and the file name tells nobody about it. Konfig never
turns plain JSON into JSONC: a raw value with a comment in a `.json` without
comments is rejected on save. JSON5, on the other hand, only applies with the `.json5` extension (a
`.json` with an unquoted key is rejected, with line and column).

In the open panel (⌘O), any file can be chosen; files starting with a
dot (`.env`) are hidden in the panel until ⌘⇧. (Command-Shift-period).

(`open -a` does not accept a relative path such as `./Konfig.app`; use the full path.)

Launched without a file, the app shows the open panel.

### The window

- **Sidebar** (in YAML, as in JSON: each block mapping is a section and each sequence
  of mappings, a group): the file's root, each `[table]` and each item of an
  `[[array of tables]]` (grouped by the array's name; an item is titled after its
  `name`, `title`, `id` or `label` field, or the Portuguese `nome`, `titulo` or `rotulo`, if present). In JSON, each
  nested `{…}` object is a section (with its path, such as `compilerOptions.paths`)
  and an array made only of objects becomes a group, with one item per object, like
  TOML's `[[array]]`. A blue dot marks the sections with unsaved changes.
- **Form**, one control per type:
  - text: a text box (confirm with Return or by leaving the field; Esc undoes the typing);
  - integer and decimal: a number box; an integer stays an integer and, on save,
    keeps its base (`0xff`, `0o755`, `0b1010`) and its `_` grouping;
  - true/false: an on/off switch;
  - **choice**: if the comment above the key (or at the end of the line) has the
    form `a | b | c`, the text becomes a list of options;
  - the 4 date/time types (with offset, local date-time, date, time): a date
    picker that respects the type; the file's offset is kept;
  - simple arrays (all items of the same type): tokens with × to remove and
    "+ add";
  - mixed arrays, arrays of inline tables and inline tables: the TOML text
    of the value, validated on confirm. In JSON, the same goes for mixed arrays,
    empty arrays and `null` (the JSON text of the value).

  Comments above the line and at its end show up as the field's help. In
  JSONC and JSON5 both `// …` and `/* … */` count, above the member or at the end of the line (before or
  after the comma) — including the `a | b | c` choice hint.
  A comment only becomes help if it is attached to the line (no blank line in between).
  The comment at the top of the file, separated from the first key or section by a
  blank line, belongs to no field: it shows up in **About this file**, at the top
  of the sidebar, as it is in the file (indentation kept), and can be edited there:
  it takes effect when leaving the box or on Apply (⌘Return), goes into ⌘Z and, on save, only the
  comment lines that changed are rewritten (a new line gets the marker of the
  comment's first line, `#`, `;` or `//`). Empty text deletes the comment.
  Loose comments in the middle of the file (with a blank line before the next
  key) remain visible only in Text mode.
- **Text** (⌘2): the whole file, editable, with simple colors (in JSON, JSONC and
  JSON5: keys in blue, strings in red, `//` and `/* */` comments in gray; in
  JSON5 also unquoted keys and single-quoted strings; in INI: `[sections]`
  in orange, keys in blue, `;` and `#` comments in gray, quoted values in
  red, with the same comment rules as the parser; in YAML: keys in blue,
  `#` comments in gray, quoted strings and the content of `|`/`>` blocks in red,
  `---` and `...` in orange). The text is only
  applied to the document if it is valid in the file's format (TOML, JSON/JSONC, JSON5, .env, INI or YAML);
  while it is not, the error shows with
  line and column and the line is highlighted. It takes effect when going back to the Form (⌘1),
  when clicking Apply (⌘↩) or on save. macOS "smart" quotes are
  turned off. If plain JSON gains a comment or a trailing comma, the footer warns
  (it is accepted, but not every program accepts JSONC).
- **Changes panel** (button on the right of the toolbar or ⌥⌘I): each piece that will
  change on disk, with the line before and after. Clicking goes to the field's section.

### Save, undo, revert

The app uses the macOS document system, so:

- ⌘S saves. **Before overwriting**, the file as it was goes to
  `<file>.bak` (`config.toml.bak`, `tsconfig.json.bak`), next to it.
- ⌘Z / ⇧⌘Z undo and redo each field change and each "Apply" in Text mode.
- The title shows "— Edited" while there are pending changes.
- File › Revert To goes back to the last saved version (or to earlier versions).
- If another program writes to the file and there are no pending edits, the window
  reloads by itself. If there are, macOS warns "changed by another application" on save.
- Before writing, the result is parsed again and checked; if it is not valid
  or the values do not match, nothing is written and the error shows. Plain JSON does not
  turn into JSONC through the form: a raw value with a comment is rejected.

## Opening with a double-click

The app declares that it edits `.toml` (type `public.toml`), `.json` (`public.json`),
`.jsonc`, `.json5`, `.env` and `.ini` (macOS does not declare these four; the app declares
`br.com.kogut.konfig.jsonc`, `br.com.kogut.konfig.json5`,
`br.com.kogut.konfig.env` and `br.com.kogut.konfig.ini`, conforming to
`public.plain-text`), always with the Editor role and `LSHandlerRank` Alternate: it does **not**
register itself as the default.

For `.ini` there is a detail: **Xcode** imports the type `com.microsoft.ini` (conforming to
`public.text`) and, on a machine with Xcode, that is the type the system gives to `.ini`
files (checked on macOS 26 with `lsregister -dump`). So Konfig declares that it
edits both, `br.com.kogut.konfig.ini` and `com.microsoft.ini`: with or without Xcode, it
shows up in "Open With". `.editorconfig` has no extension as far as the system is concerned; like
`.env`, it is recognized by name inside the app (`open -a`, ⌘O or dragging onto the icon).

Why `public.plain-text` and not `public.json` as the parent type of `.jsonc` and
`.json5`: in a test on macOS 26.7 with two dummy apps declaring new
extensions, one conforming to each, the file conforming to plain text was indexed by
Spotlight (RichText importer) and the one conforming to `public.json` got no importer
at all; plain text's "Open With" offers the text editors (TextEdit, Xcode…);
and, since JSONC and JSON5 are not valid JSON, it is better that programs that only accept
strict JSON do not offer to open them. Both types have a Quick Look preview. The declared `.env` type only covers names such as
`production.env`: `.env` and `.env.local` have no `env` extension as far as the system is concerned, so the
Finder does not associate them with Konfig; open them with `open -a`, with the app's ⌘O or
by dragging onto the icon. To associate an extension:

1. Copy `Konfig.app` to `/Applications` (optional, but then it does not depend on this folder).
2. In the Finder, select a file with that extension › File › Get Info (⌘I).
3. Under "Open with", choose Konfig and click **Change All…**.

Without that, it shows up in "Open With" (right-click on the file).

For YAML there is no type to declare: macOS already has `public.yaml` (extensions `.yaml` and `.yml`,
conforming to `public.text`; checked on macOS 26 with `UTType(filenameExtension:)`). Konfig
just says that it edits it, also with the Editor role and `LSHandlerRank` Alternate.

## Limitations

- Creating keys or tables is not done through the form — use Text mode.
- Multi-line arrays: if the **number** of items changes, the array is rewritten
  with the first item's indentation and the trailing comma, if there was one; comments *inside*
  it are lost. If only item values change, the rest of the array stays intact.
- A simple array that becomes a mixed array (or the other way round) has to be edited in Text mode.
- The date picker does not edit fractional seconds (they are kept) and does not show year 0000.
- Multi-line strings appear in a box that grows, but Return confirms; to break lines comfortably, use Text mode.
- macOS automatically saves edited documents (when switching apps, closing the
  window etc.), as in TextEdit. Every save, including the automatic ones, renews
  the `.bak` with the previous version.
- No schema validation, Quick Look or comparison between files.

### JSON, JSONC and JSON5

- Strings: the unchanged parts at the start and at the end are copied byte for byte
  (escapes included); the new part follows the original's habit: `\/` if it
  escaped the slash, `\u00e9` if it escaped accented letters, same case in hexadecimal.
- Numbers: an integer stays an integer; a decimal stays a decimal, with an exponent if
  it had one (`1.5e3` → `2.0e3`, same letter `e`/`E` and the `+`) and with at least the
  same number of digits after the point (`1.50` → `2.25`, `1.50` → `3.00`). JSON has no
  infinity or NaN: such a value is rejected.
- Duplicate key: the last one wins (as in JavaScript, Python and Go; Apple's
  `JSONSerialization` keeps the first). Only the last one shows in the
  form, and that is the one written.
- A root that is not an object: an array of objects becomes a group of items; any
  other value shows as a single field, "(root)".
- `//` comments before the opening `{` do not show as help (they belong to no field):
  they go to "About this file".
- Arrays whose number of items changes follow the TOML rule: rewritten with the
  first item's indentation and the trailing comma if there was one (in single-line or
  multi-line arrays); comments inside them are lost. If only item values change, the
  comments stay. An object's trailing comma is never touched (only values are rewritten).
- Cases the specification leaves up to the parser (`i_` in the JSONTestSuite):
  - **accepted**: out-of-range numbers — an integer that does not fit in 64 bits becomes an
    approximate decimal, a huge exponent becomes infinity or zero (they are only rewritten
    if the field is edited, and infinity cannot be written); a UTF-8 BOM at the start
    (kept on save).
  - **rejected**: a file that is not UTF-8 (ISO-8859-1, UTF-16, invalid
    sequences); a `\u` escape of an unpaired surrogate (`"\uD800"`), which does not fit in a
    valid Unicode string; more than 128 levels of nested arrays/objects.

#### JSON5

Follows specification 1.0.0 (spec.json5.org). On top of what JSONC accepts:

- unquoted keys that are JavaScript identifiers (Unicode letters, `$`, `_`,
  digits after the first character, `\uXXXX` escapes), and single-quoted keys;
- single-quoted strings; line continuation with `\` at the end of the line (LF, CRLF, CR,
  U+2028 or U+2029); escapes `\'`, `\v`, `\0`, `\xHH`, and any other escaped character
  stands for itself (`\a` is `a`); `\1` to `\9` are errors;
- hexadecimal numbers (`0x1F`, `0XAB`, also signed), `Infinity`, `-Infinity`,
  `NaN`, a `+` sign, `.5` and `5.`; a leading zero (`010`) is still an error;
- whitespace: vertical tab, form feed, no-break space (U+00A0), a BOM in the
  middle of the file, the whole Unicode Zs category and the separators U+2028/U+2029;
  CR-only line breaks.

On save, each value keeps its style:

- single quotes stay single (a `'` in the new text is escaped as `\'`); double
  quotes stay double; the unchanged start and end are copied byte for byte,
  including `\x41` escapes and `\` line continuations;
- a hexadecimal integer stays hexadecimal, with the same `0x`/`0X`, the same digit
  case and at least the same width (`0x00FF` → `0x000A`); a negative one becomes `-0x…`;
- `+` is kept (`+7` → `+8`, `+1.50` → `+2.25`); `.5` → `.25`; `5.` → `6.` (and `6.5`
  when the value has a fraction); infinity and NaN are written as `Infinity`, `-Infinity`
  and `NaN` (JSON5 accepts them, JSON does not);
- decimals follow the JSON rules (exponent, digits after the point).

Limitations: an integer larger than 64 bits (hexadecimal included) becomes an approximate
decimal; a `\u` escape of an unpaired surrogate is rejected, as in JSON; `-NaN` is
read as NaN (the sign is lost if the field is edited); the key is never rewritten (to
rename, use Text mode); in a file with CR-only line breaks, the line number in errors
counts only LF and comes out wrong.

### .env

- Every value is text and there are no sections: the form shows a single section, "Variables".
  An `a | b | c` comment becomes a choice, as in TOML.
- A line the parser does not understand is an error (with line and column), instead of being
  ignored as `dotenv` does: that way nothing disappears on save. A duplicate key is also an
  error, so as not to edit the wrong variable.
- Multi-line values: only inside quotes. When editing, the new text uses `\n` (double
  quotes) or the file's line break (single quotes that already spanned several lines).
- Text mode coloring is per line; multi-line quoted values
  are colored only on their first line.
- Creating or deleting variables: through Text mode.

### .env rules

There is no official standard; these are the exact rules Konfig accepts, chosen
from what Node's and Ruby's `dotenv` have in common.

- File in UTF-8, with or without BOM; LF or CRLF line breaks (kept on save).
  A lone CR is an error.
- Each line is one of these:
  - blank (only spaces and tabs);
  - comment: `#` at the start (spaces before it are allowed);
  - `KEY=value`, with an optional `export ` in front, optional spaces and tabs
    at the start of the line and around the `=`.
- Key: ASCII letters, digits, `_`, `.` and `-` (`[A-Za-z0-9_.-]+`). `export=1` is the
  variable `export`; `export A=1` is the variable `A`.
- Unquoted value: runs up to the first `#` or the end of the line; spaces and tabs
  at either end are not part of it (`A = x y  # c` → `x y`). The `#` starts a
  comment even with no space before it (`A=abc#def` → `abc`, as in `dotenv`). An empty value
  (`A=`) is empty text.
- `'single quotes'`: literal, no escapes; may contain `#` and span several lines.
- `"double quotes"`: escapes `\n` (line break), `\r`, `\"` and `\\`; any
  other backslash stays as is (`"c:\folder"` → `c:\folder`). May span several lines.
- Inside quotes, a CRLF break counts as `\n` (as in `dotenv`).
- After the quotes, only spaces and an optional `#` comment.
- A backtick (`` ` ``) is not a quote: `` A=`x` `` is the text `` `x` ``.
- `${VAR}` and `$VAR` are **not** expanded: they are text.
- Comments on their own lines right above the variable (no blank line in
  between) and the comment at the end of the line become the field's help.

On save, the kind of quotes is kept:

- unquoted stays unquoted if the new value fits: empty, or with no space,
  tab, `#`, quotes (`"`, `'`, `` ` ``) or control characters. If it does not
  fit, double quotes;
- single quotes stay single if the value has no `'` and no CR (and a line break
  only if the original already had one); otherwise, double quotes;
- double quotes stay double: the unchanged start and end are copied
  byte for byte, and the new part escapes only `\`, `"`, line break and CR.

### INI

- Every value is text; each `[section]` is an item in the sidebar and the keys before the
  first section go to "General". An `a | b | c` comment becomes a choice.
- `key[] = …` arrays (PHP style) show as tokens. Adding an item
  adds **one line**, right after the array's last one, copying its beginning
  (indentation, key, separator and spaces); removing an item removes **its line** (the
  comment that was above it stays). An array cannot be left empty through the
  form: to delete it, use Text mode.
- If another key sits among an array's items and both are changed,
  the changes are applied one at a time (the array's span goes from the first
  to the last item and contains the other key); the result is the same.
- There are no escapes: a value with a line break cannot be written, nor one that
  needs quotes and has both double **and** single quotes.
- The file must be UTF-8 (with or without BOM). A `desktop.ini` written by
  Windows is usually UTF-16 or in the system code page: it is rejected.
- Creating keys and sections: through Text mode.

### INI dialect

INI has no standard: Windows (`GetPrivateProfileString`), PHP (`parse_ini_file`),
Python (`configparser`) and Git (`git config`) follow different rules. Konfig
accepts exactly these, chosen to open the most common files without surprises
(`php.ini`, `.editorconfig`, `desktop.ini`, files of games and Windows programs) and
to never guess: anything ambiguous is rejected, with line and column, instead of being
read in a way the program that owns the file might not read it.

- File in UTF-8, with or without BOM; LF or CRLF line breaks (kept on save). A lone
  CR is an error.
- **Blank lines** are preserved and separate a comment from the following key.
- **Line comment**: `;` or `#` at the start of the line (spaces before it are
  allowed). The comments right above a key (no blank line in between)
  become the field's help, without the repeated markers (`;; text` → `text`).
- **Section**: `[name]`. Spaces inside the brackets are part of the name, except
  those at either end (`[ CLI Server ]` → `CLI Server`). Dots are literal: `[a.b]` is the
  section `a.b`, not a subsection of `a`. The name runs up to the first `]` followed
  only by spaces and, optionally, a comment; so `[*.[ch]]` (EditorConfig) is the
  section `*.[ch]` and `[a] ; note` is the section `a` with the comment `note`. A section without a name
  (`[]`) is an error. A section that appears again continues the first one (the keys are
  merged; repeating a key across the two parts is an error).
- **Keys before the first section** go to the "General" section.
- **Pair**: `key = value` or `key: value`; the first `=` or `:` on the line counts
  (`url = http://x` has the key `url`). The separator and the spaces around it
  are never rewritten. The key is the text before the separator, trimmed at both ends.
- **Unquoted value**: spaces at either end are not part of it (and stay in the
  file). It ends at a comment: `;` or `#` **after a space or tab**
  (`a = x ; note`). With no space before them, they are part of the value: `url = http://x/#a` and `a = b;c`.
  Two cases at the start of the value: `;` is a comment (`a = ; note` is an empty value, as
  in PHP) and `#` is a value (`color = #DD0000`, see below).
- **Quoted value**, double or single, **with no escapes** (`\` is a backslash); the quote
  closes on the same line, and after it only spaces and a comment may follow.
  `"  with spaces ; and # inside  "` keeps all of that.
- **Every value is text**: there is no way to know whether `On`, `yes` or `1` is a yes/no (PHP
  says yes, for Python it depends on who reads it, EditorConfig only accepts `true`).
- **PHP-style arrays**: several `key[] = value` lines in the same section form an
  array (`ext [] =` is the same array). Repeated `extension` and `zend_extension` keys
  also form an array (see below).
- **A key repeated without `[]` in the same section is rejected**, with line and column: editing
  one of them might mean editing the one the program ignores. `x` and `x[]` in the same section
  also collide.
- **A line that is not a section, pair or comment is rejected**, with line and column.

On save, the value's kind of quotes is kept: unquoted stays unquoted if the
text fits (no spaces at either end, no `;`, no `#` at the start or after a space,
not starting with a quote); if it does not fit, double quotes (or single, if the text has
`"`). Double quotes stay double and single stay single, unless the text
contains that quote. An empty value in `key =` gets a space after the `=` (`key = new`).

**Adjustments made while testing with real files** (the rule as first specified was
changed on these points):

- `#` **at the start of the value is a value**, not a comment. The official `php.ini-production` and
  `php.ini-development` contain `;highlight.string  = #DD0000` (and four more
  colors): uncommented, the line has to yield the color `#DD0000`, which is what PHP reads (PHP
  has not used `#` for comments since version 7). With the rule "`#` after a
  space is a comment", the value would be empty. On save, a text starting with `#`
  is quoted, so as not to depend on this.
- `;` at the start of the value is still a comment (`key = ; note`), as in PHP and Windows.
- Repeated `extension` and `zend_extension` **are an array**, not an error. That is the
  documented way to load extensions in `php.ini` (`;extension=curl`,
  `;extension=gd`… uncommented, one per line); rejecting the repetition would keep almost every
  real-world `php.ini` (Windows, XAMPP) from opening. For any other key the
  repetition is still rejected.
- The section name runs up to the **first `]` followed only by spaces or a comment**, and
  not up to the first `]`: `.editorconfig` uses globs with brackets, such as `[*.[ch]]`.
- A value written without quotes also cannot contain `;` anywhere (not even without a space), because
  PHP cuts the value at the `;`: `a = b;c` is read by Konfig as `b;c`, but a new
  value `b;c` is written as `"b;c"`, which both read the same way.

**Outside the dialect** (and how they show up if the file has them):

- **Multi-line value continuation** (Python's `configparser`: the following
  line indented): the continuation line has neither `=` nor `:`, so the file is
  rejected with an error on that line. If the continuation has `=` or `:`, it becomes a
  separate key (an indented `  b = 2` is the key `b`).
- **Interpolation** `%(x)s` (Python) and `${x}` (PHP, Python's `ExtendedInterpolation`):
  stays as text, not expanded (`%(home)s/bin` is exactly that text).
- **Git subsections** (`[remote "origin"]`): the section name is the whole text,
  `remote "origin"`, quotes included; the keys can be edited, but Konfig does not know
  it is the `origin` subsection of `remote`. Git's repeated keys (`fetch` several
  times) are rejected, and `.gitconfig` is not associated with Konfig.
- **Key without a value** (`skip-networking` in `my.cnf`, Python's `allow_no_value`):
  rejected as a line that is not a pair.
- **Escapes** inside double quotes (`\"`, `\n`, PHP's `${VAR}` inside quotes): stay
  as they are in the text (PHP expands some; Konfig shows the raw text).

### YAML

#### Accepted subset

The full YAML 1.2 specification (anchors, type tags, several documents in one file, complex
keys) would be a bigger project than the rest of the app. Konfig reads the subset found in
configuration files:

- **One document per file**, with an optional `---` at the start and an optional `...` at the end (after
  the `...`, only comments). An empty file, or one with only comments, is a file with no values.
- **Block mappings** (`key: value`, nested by indentation) and **block sequences** (`- item`),
  including sequences of mappings (`- name: x` with the following lines indented), a sequence at the same
  indentation as its key (`key:` and `- a` on the next line) and compact sequences and mappings (`- - a`, `- a: 1`).
  Indentation is spaces only: a tab in the indentation is an error, as the specification says. A duplicate key in the
  same mapping is an error (the specification forbids it too).
- **Values**: plain (single- or multi-line; line breaks become spaces and blank lines,
  `\n`); single-quoted (`''` is one quote); double-quoted, with every escape in the
  specification (`\n`, `\t`, `\x41`, `\u00e9`, `\U0001F600`, `\N`, `\_`, `\L`, `\P`, escaped line break…);
  block scalars, `|` (literal) and `>` (folded), with the chomping indicators `-` and `+` and the indentation indicators `1`–`9`.
- **Flow collections** `[a, b]` and `{a: 1, b}`, also across several lines and nested,
  with a single pair inside a sequence (`[a: 1]`) and a key without a value (`{a, b: 1}` has `a: null`).
- **`#` comments** (with a space before them): those right above a key (no blank line
  in between) and the one at the end of the line become the field's help; `a | b | c` becomes a list of options.
- File in UTF-8, with or without BOM; LF or CRLF line breaks (kept on save). A lone CR and
  control characters are rejected.

In the form: each block mapping is a section and each sequence of mappings a group (as in JSON);
a sequence (block or flow) whose items all have the same simple type shows as
tokens; flow mappings (`{a: 1}`), mixed sequences, sequences of sequences, empty values (`key:`)
and `null` show as raw text (YAML), just like in TOML.

#### Types: the YAML 1.2 *core schema*

A plain (unquoted) value has the type the YAML 1.2 *core schema* says, and only those:

| unquoted text | type |
|---|---|
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | yes/no |
| `null`, `Null`, `NULL`, `~` and the empty value | null |
| `12`, `-3`, `+7`, `0x1F`, `0o17` | integer (`010` is ten) |
| `1.5`, `.5`, `1.`, `1e3`, `-2.5E-3`, `.inf`, `-.Inf`, `.nan` | decimal |
| everything else: `yes`, `no`, `on`, `off`, `y`, `n`, `0b101`, `1_000`, `12:30`, `2024-01-31`… | text |

Quoted or in a block, it is always text. Why 1.2 and not 1.1: it is the current version of the
specification (2009), the one YAML itself recommends and the one the yaml-test-suite uses; Konfig has no way of knowing
which program will read the file, and 1.2 is the one that changes least of what is written (`no` stays
`no`). Dates do not exist in 1.2: `2024-01-31` is text.

#### Protective quotes (YAML 1.1 readers)

Many programs still read YAML by the old rule, 1.1 (PyYAML and, with it, Ansible and
the Python docker-compose; Go's `yaml.v2`; Ruby's Psych): for them `no`, `off` and `n` are
**false**, `on` and `yes` are true, `010` is **eight** (octal), `1_000` is a thousand, `12:30` is 750
(sexagesimal), `2024-01-31` is a date. This is the classic Norway problem: `country: NO` becomes `country: false`.

That is why, **when writing an unquoted string**, Konfig adds double quotes when the text would be read
as another type by YAML 1.2 **or** by 1.1, even if in 1.2 it is already text:

- 1.1 yes/no and null, in any case: `y`, `n`, `yes`, `no`, `on`, `off`, `true`, `false`, `null`, `~`, empty;
- anything that starts with a digit (or `.` and a digit, after the sign) and contains only digits, `.`, `:`,
  `_`, `e`, `x`, `o`, `b`, signs and the letters `a` to `f`: `1e3`, `010`, `0x1F`, `0b11`, `1_000`,
  `12:30`, `8080:80`, `1.5`, `1.2.3`;
- `.inf`, `-.inf`, `.nan`, dates (`2024-01-31…`), `<<` and `=`.

The rule is deliberately broad: extra quotes change the value for nobody; missing quotes change the
type in some program. It only applies to text **written by Konfig**: a `country: no` already in
the file is read as text (YAML 1.2) and is not touched if the field is not edited.

#### Outside the subset: opens in Text mode only

Anchors and aliases (`&base`, `*base`), merge keys (`<<:`), tags (`!!str`, `!Ref`, `!!binary`),
several documents in the file, complex keys (`? key`, `[a, b]: x`), empty or null keys
(`: x`, `~: x`) and directives (`%YAML`, `%TAG`) are left out. A file with any of them **opens
in Text mode only**, with a notice saying what is not accepted and on which line (for example "line 3:
anchor (&) is outside the subset Konfig edits through the form"). The form is
unavailable; the text can be edited and saved, and is written as is (with the `.bak`), without the
re-parse and check the form does. If the text comes back inside the subset, the form
works again; a real syntax error still prevents applying and saving.

Why open in Text mode instead of rejecting: these are valid and common YAML files (anchors in
docker-compose and GitHub Actions, `!Ref` in CloudFormation); rejecting them would force opening another
editor to change one line. Why not in the form: with an alias, changing the anchor's value
would change several places at once, and a tag changes the value's type — the form would show
something different from what the program reads. The parser never ignores these features silently: when it finds
one of them, it stops and says so. (An invalid file that also uses one of these features may get the
same notice instead of the syntax error — in the yaml-test-suite, 22 of the 94 invalid cases; in both
cases the form does not open.)

#### Writing

- Only the bytes of the changed value change. The kind of quotes is kept: unquoted stays unquoted
  when it fits; single quotes stay single; double quotes stay double; a `|`/`>` block
  stays a block, with the same indentation, the same indentation indicator and the header comment.
- Text needs (double) quotes when it is empty or has spaces at either end, contains `: ` or ` #`, ends with
  `:`, starts with an indicator (`- `, `?`, `:`, `,`, `[`, `]`, `{`, `}`, `#`, `&`, `*`, `!`, `|`, `>`,
  `'`, `"`, `%`, `@`, `` ` ``), or has a line break, tab or control character — plus the cases of the
  [protective quotes](#protective-quotes-yaml-11-readers). Inside `[ ]`, also `,[]{}`.
- In a block, the chomping indicator follows the new text: no trailing line break, `|-`; one, `|`;
  more than one, `|+`. In a `>`, each line break becomes a blank line; if any line starts
  with a space (which `>` does not fold), the block becomes `|`. If the first line starts with a space and there
  is no indentation indicator, or the text has control characters, it goes in double quotes.
- A **block sequence** that changes size: an extra item is a new line (`- value`) right after the
  last item, with its indentation and `- ` and the quotes of the last item of the same type; a removed item is
  its line taken out (the other lines' comments stay). A sequence that becomes empty becomes `[]`.
- A **flow sequence** that changes size: as in TOML and JSON (rewritten in the style of the
  first item; comments inside it are lost).
- A number keeps the same form (`0x`, `0o`, `+`, exponent, decimal places); `True` stays
  capitalized; `.Inf` stays `.Inf`. YAML (core schema) has no date type: a date value is rejected.
- An empty value (`key:`) gets a space before the new value (`key: new`).

Limitations: keys are not rewritten (to rename, use Text mode); comments inside
flow collections do not become help; a multi-line plain string, once edited, is written
on a single line; a block sequence with compact items (`- - a`) that changes size is rewritten
in flow style; Text mode coloring is per line (a multi-line quoted string is colored
only on its first line).

### Next formats

The part specific to each format lives in `Format.swift` (which parser, which writer
and what the format does not accept) and in an `XReader.swift`/`XFormat.swift` pair; `Writer`,
`EditSession`, `Fields` and the user interface are already shared. To add a format:

- **Full YAML** (anchors, tags, several documents): would require editing values that
  appear in several places at once; today these files open in Text mode only.

### Name changes in the code (for `ConfCore` users)

**2026-10-11: English API.** For the open-source release, the whole public `ConfCore` API
(and the rest of the code) was renamed to English. The old aliases `DocumentoTOML`,
`ErroTOML` and `EdicaoTOML` were **removed**; code using the Portuguese names must switch to the new ones.
The main ones:

| before | now |
|---|---|
| `DocumentoConf` (and the alias `DocumentoTOML`) | `ConfDocument` |
| `ErroLeitura` (and the alias `ErroTOML`) | `ParseError` |
| `Edicao` (and the alias `EdicaoTOML`) | `EditSession` |
| `Formato` | `Format` |
| `Valor` | `Value` |
| `Caminho` | `ValuePath` |
| `Tabela` | `Table` |
| `DataHora` | `DateTime` |
| `Entrada` | `Entry` |
| `TipoCampo` | `FieldKind` |
| `Leitor` | `TOMLReader` |
| `LeitorJSON`, `LeitorEnv`, `LeitorINI`, `LeitorYAML` | `JSONReader`, `EnvReader`, `INIReader`, `YAMLReader` |
| `FormatarJSON`, `FormatarEnv`, `FormatarINI`, `FormatarYAML` | `JSONFormat`, `EnvFormat`, `INIFormat`, `YAMLFormat` |
| `Gravar` | `Writer` |
| `Abertura` | `Preamble` |

Members followed the same rule (`formato` → `format`, `valorRaiz` → `rootValue`,
`nomeFormato` → `formatName`, `raiz` → `root`, `ehJSON` → `isJSON`, `ler` → `parse`,
`escrever` → `write`, `aplicar` → `apply`, `alteracoes` → `changes`, `nulo` → `null`,
`cru` → `raw`, `foraDoSubconjunto` → `outsideSubset`, `somenteTexto` → `textOnly`,
`trocarTexto` → `replaceText`, `ajustarCru` → `adjustRaw`…). Messages shown on screen
are now localized (see [Localization](#localization)).

**Earlier** (when the app started editing more than one format), shown with today's names:

| before | after |
|---|---|
| `DocumentoTOML` | `ConfDocument` (with `format`, `rootValue` and `formatName`; `root` is still the `Table`) |
| `EdicaoTOML(bytes)` | `EditSession(bytes, format:)` (`.toml` by default) |
| `ErroTOML` | `ParseError` (with `format`; the message names the format, as in "invalid TOML" or "invalid JSON") |

Also: `Format` (`.toml`, `.json`, `.json5`, `.env`, `.ini`, `.yaml`; `isJSON` for both JSONs)
dispatches parsing a file, parsing a value and writing (`JSONReader.parseJSON5` for JSON5),
and `Format(fileName:)` picks one from the file name;
`Writer.apply(bytes, changes:, format:)`; `Value.null`; `FieldKind.raw.name`
is "raw text" and `name(at: format)` gives "TOML" or "JSON".
With YAML: `ParseError.outsideSubset` (a valid file that can only be edited as text),
`EditSession.textOnly` and `replaceText` accepting such text, and `Format.adjustRaw` (raw text
typed by the user is adjusted to its place before saving; in the other formats, it changes nothing).

## Localization

The user interface follows the macOS language: English by default, Portuguese (pt-BR) available. The strings
live in `Resources/<lang>.lproj/Localizable.strings`, with the English text as the key
(`NSLocalizedString("Apply", …)` in the code); document type names live in
`InfoPlist.strings`, in the same folder. `build.sh` refuses to build if any key used in the
source is missing from any language.

To add a language:

1. Copy `Resources/en.lproj` to `Resources/<lang>.lproj` (for example `es.lproj`).
2. Translate the values (the right-hand side of `=`) in `Localizable.strings` and `InfoPlist.strings`;
   leave the keys as they are.
3. Add the language code to `CFBundleLocalizations` in `Info.plist`.

## Organization

Code, comments and identifiers are in English.

```
Package.swift
Info.plist             the app's (document types, CFBundleLocalizations)
build.sh               checks the translations, builds and assembles Konfig.app
Sources/ConfCore/      parsers, model and writing (no user interface)
  Format.swift         TOML, JSON, JSON5, .env, INI or YAML: which parser and which writer to use
  TOMLReader.swift     TOML 1.0 → structure, with the byte range of each value
  JSONReader.swift     JSON/JSONC/JSON5 → structure, with ranges and comments
  Writer.swift         replaces only the changed bytes, in the original style (TOML)
  JSONFormat.swift     writes JSON/JSON5 values in the original's style
  EnvReader.swift      .env → structure, with ranges and comments
  EnvFormat.swift      writes .env values keeping the kind of quotes
  INIReader.swift      INI → structure (sections, `key[]` arrays), with ranges and comments
  INIFormat.swift      writes INI values keeping the quotes; adds/removes array lines
  YAMLReader.swift     YAML (configuration subset) → structure, with ranges and comments
  YAMLFormat.swift     writes YAML values in the original's style; protective quotes; block sequences
  Fields.swift         structure → on-screen sections and fields
  Preamble.swift       the comment at the top of the file ("About this file"): reading and rewriting
  EditSession.swift    state of an open file; line-based diff
  Model.swift          types (Value, DateTime, Entry, ConfDocument, …)
Sources/Konfig/        the app (NSDocument + SwiftUI)
  App.swift            app startup, menus, document controller, km-conf migration
  Document.swift       the NSDocument and the window model: open, save, .bak, undo
  WindowView.swift     the window: sidebar, form, "About this file", changes
  FieldView.swift      one control per field type
  TextModeView.swift   Text mode, with colors
  SelfTest.swift       the self-test (KONFIG_SELFTEST, see below)
Resources/             en.lproj and pt-BR.lproj (Localizable.strings, InfoPlist.strings)
Tests/ConfCoreTests/   toml-test, JSONTestSuite and json5-tests suites (Fixtures/,
                       MIT license), a sample tsconfig.json, JSONC files
                       (Fixtures/jsonc/), .env (Fixtures/env/), INI (Fixtures/ini/:
                       hand-written, .editorconfig from EditorConfig and an excerpt of php.ini,
                       MIT and BSD licenses alongside), yaml-test-suite (Fixtures/yaml/,
                       MIT license, SOURCE.txt with the commit), PreambleTests and
                       WriterTests (writing)
icon/                  Konfig.icns, the konfig.svg drawing and make-icon.sh
docs/ideas/            archived ideas (rust-multiformat-library.md: a multi-format Rust
                       library, dropped)
examples/config.toml
examples/config.json
examples/config.jsonc
examples/settings.jsonc
examples/config.json5
examples/.env
examples/config.ini    (with CRLF)
examples/config.yaml   (in the style of a docker-compose file)
```

### Keyboard-free diagnostics

```sh
KONFIG_SELFTEST="/tmp/x/config.toml|/tmp/x/out" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/config.json|/tmp/x/out-json" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/config.jsonc|/tmp/x/out-jsonc" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/settings.jsonc|/tmp/x/out-settings" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/config.json5|/tmp/x/out-json5" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/.env|/tmp/x/out-env" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/config.ini|/tmp/x/out-ini" Konfig.app/Contents/MacOS/Konfig
KONFIG_SELFTEST="/tmp/x/config.yaml|/tmp/x/out-yaml" Konfig.app/Contents/MacOS/Konfig
```

The file must be a copy of `examples/config.toml`, `examples/config.json`,
`examples/config.jsonc`, `examples/settings.jsonc`, `examples/config.json5`,
`examples/.env`, `examples/config.ini` or `examples/config.yaml` (the script relies on their fields; the copy of `.env` may be
named `.env`, `.env.local` or `something.env`; a copy of `config.jsonc` named
`something.json` tests the "JSON with comments" notice). It opens the **copy** (it is modified and then restored), changes three
values through the same path as the controls, saves, undoes, tests Text mode and
reloading after an external change, and writes `report.txt` and screenshots of the window to the output
folder. For INI, it also adds an item to the `extensions[]` array (checking that it is a single
new line and nothing else) and undoes it; a copy of `config.ini` named `.editorconfig`
checks that ⌘S keeps the name (it does not save `.editorconfig.ini`). For YAML, it does the same with the
block sequence `services.web.ports` and checks that a text with an anchor gives an "outside the subset" notice
(not an error) in Text mode.

## Coming from km-conf

Until 2026-10-11 the app was called km-conf, with the identifier `br.com.kogut.km-conf`; now it is
`br.com.kogut.konfig`, and the `.jsonc`, `.json5`, `.env` and `.ini` types became
`br.com.kogut.konfig.*`. On first launch, Konfig copies the preferences stored under the
old identifier (window position and size, last folder of the open panel). Not carried over,
because macOS stores them per identifier outside the preferences: the **Open Recent** list and
the associations made with **Change All…** in the Finder (redo them choosing Konfig). An old
`km-conf.app` can be deleted; while it exists, it also shows up in "Open With".

## License

[MIT](LICENSE), © 2026 Kogumelo Informática Ltda. Use, copy and modify it
freely, keeping the copyright notice. The code comes with no warranty. The third-party
test cases in `Tests/ConfCoreTests/Fixtures/` have their original license alongside.
