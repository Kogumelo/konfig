# Konfig

- Tests: `swift test` (ConfCore only, ~10 s warm, ~40 s cold). Kommand runs a gate on every merge into main — `swift build && swift test`, and `./build.sh` on top for deploys (`[code]` in `~/.kommand/projects/konfig.toml`); a red gate undoes the merge. Tests that write files use a temporary folder, never a real config.
