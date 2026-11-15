# Qualflare for Tern

A [Tern](https://docs.stencil.so/tern/) plugin for [Qualflare](https://qualflare.com). It turns test runs in your terminal into Qualflare uploads, and shows launches and failures as native views.

```sh
tern plugin install github.com/Qualflare/qualflare-tern
```

It needs the [Qualflare CLI](https://github.com/qualflare/qualflare-cli) (`brew install qualflare/tap/qf`), logged in with `qf login <identifier>`. The plugin never sees your token: every call goes through `qf`. A project is set up when it has `.qualflare/test-state.md`, which `/qf-init` writes in Claude Code or omp ([qualflare-claude-code](https://github.com/Qualflare/qualflare-claude-code)).

Both halves are included: `host.luau` runs in Tern's session daemon, `window.luau` in each window.

## What it does

**Upload prompt after tests.** When a test command finishes in a Qualflare project and has written new reports to `qualflare-results/` or `.qualflare/results/`, Tern types `qf <identifier> collect <reports>` at your prompt. Press Enter to upload, or clear it. Nothing runs on its own. A test run that writes no report file (a plain `go test ./...`) doesn't trigger it; use a Qualflare reporter, `--junitxml`, or Playwright's JSON reporter.

**Native `qf` output.**
- `qf <id> collect …` shows a result card: uploaded, not logged in, plan limit, retry. It also shows skipped attachments and an *Open launches* button.
- `qf <id> launches list`, `clusters list` and `defects list` show a table instead of JSON. Double-click a row, or press its open button, to see it in the dashboard. The *Raw* toggle shows the JSON.

**Launches pane.** *Qualflare: Show launches* in the palette opens a pane with the latest launch's numbers, recent launches and the top failure clusters. It refreshes every minute; press `r` to refresh now.

**Palette commands.**

| Command | What it does |
|---|---|
| *Qualflare: Show launches* | Opens the launches pane for the focused pane's project |
| *Qualflare: Upload test results* | Types `qf <id> collect <report folder>` into the focused pane |
| *Qualflare: Open dashboard* | Opens the project in the browser |
| *Qualflare: Fix failing tests with omp* | Starts an omp agent on `/skill:qf-fix` (needs the Qualflare plugin in omp) |
| *Qualflare: Toggle upload prompt after tests* | Turns the upload prompt on or off |

**Status widget.** *Qualflare upload* shows the last `qf collect` result. Add it from the palette with *Edit widgets…*.

**Carly.** Carly can call `plugins.qualflare.launches()`, `clusters()` and `project()`, and knows which Qualflare project the focused pane is in. Ask it "what failed in the last launch?".

## Settings

Settings live in the plugin's `kv.json` (`<state>/plugin-data/qualflare/`):

| Key | Default | Meaning |
|---|---|---|
| `auto_prompt` | `true` | The upload prompt after test runs |
| `qf_path` | found on `PATH`, then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/go/bin` | The `qf` executable |
| `report_dirs` | `[]` | More report folders to watch, relative to the package |
| `slugs` | `{}` | Dashboard slug per `qf` identifier, when they differ (`{"web": "acme-web"}`) |

## Development

```sh
tern plugin link .            # load it from this folder; saving reloads it
tern plugin types .           # regenerate tern.d.luau after upgrading Tern
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau
python3 tests/bundle.py /tmp/qf-tests.luau && luau /tmp/qf-tests.luau
```

The tests run the plugin's handlers against a stand-in `tern` API (`tests/stub.luau`). `tests/bundle.py` puts everything in one chunk because the Luau CLI gives modules read-only globals. Plugin logs: start Tern with `STENCIL_LOG=warn,stencil=info,tern::plugin=debug`.

## License

Apache-2.0
