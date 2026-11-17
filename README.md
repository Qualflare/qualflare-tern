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

**Qualflare pane.** *Qualflare: Show launches* opens a Qualflare pane beside the focused one, for that pane's project:
- one line on the latest run (`✗ 8 of 120 failing · main · Staging · 12 min ago`), what changed since the run before (`+2 tests · 8 more failing than #41`), or a reminder when the last run is over a week old;
- the pass rate of the last 20 runs as bars, red where a run failed;
- the recent launches and, for the selected one, Qualflare's AI summary (risk, failing areas, recommendations);
- when the latest run failed, *Where to look*: the three most recently seen failure clusters.

*Open on website* shows the launch's test results in the dashboard. *Fix with omp* starts omp on a failed launch. *Upload* types `qf <id> collect …` into a terminal of the project. A menu at the top switches between the projects you're logged in to (`qf projects`). The pane refreshes every minute, and at once when `qf <id> collect` finishes in any terminal, selecting the new launch and marking it *new*.

Keys: `↑`/`↓` select, `⏎` open on website, `r` refresh, `u` upload, `p` project.

Clicking a dashboard launch link (`https://app.qualflare.com/project/<slug>/launches?…p.seq=<n>`) in a terminal opens the Qualflare pane on that launch, when you're logged in to that project. Turn this off with *Qualflare: Toggle opening Qualflare links in Tern*.

**Palette commands.**

| Command | What it does |
|---|---|
| *Qualflare: Show launches* | Opens the Qualflare pane beside the focused pane, for its project |
| *Qualflare: Upload test results* | Types `qf <id> collect <report folder>` into the focused pane |
| *Qualflare: Open dashboard* | Opens the project in the browser |
| *Qualflare: Fix failing tests with omp* | Starts an omp agent on `/skill:qf-fix` (needs the Qualflare plugin in omp) |
| *Qualflare: Toggle upload prompt after tests* | Turns the upload prompt on or off |
| *Qualflare: Toggle opening Qualflare links in Tern* | Dashboard launch links open in the Qualflare pane, or in the browser |

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
| `route_links` | `true` | Open dashboard launch links clicked in terminals in the Qualflare pane |

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
