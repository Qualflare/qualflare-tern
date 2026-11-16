# Qualflare tab: design

Date: 2026-11-16. Status: awaiting approval.

## Intent

A Qualflare tab in Tern, a pane type of its own like Tern's Git, Database or
Browser views, not something inside the terminal. Its subject is **the latest
launches**: has the latest run passed, what changed, and where to look next.
The details of one launch, such as which tests failed and their errors, stay
on the website; the tab links there.

## Goals

- See a project's recent launches and how the latest is doing, at a glance.
- Select a launch to read its numbers and Qualflare's AI summary of it.
- Jump to the launch on the website, preferably in Tern's own browser.
- Open the tab from the palette, from Qualflare links clicked in panes, and
  from the plugin's existing commands.

## Non-goals

- Per-test results inside the tab. The CLI has no command for them (`qf
  launch get` returns counts and the AI summary only), and the website already
  shows them.
- Clusters, defects, test cases, plans or milestones views. They can come back
  later as tabs.
- Changing anything on the server, such as marking defects or assigning
  failures. The tab only reads, apart from the existing upload button, which
  types a command for the user to run.

## Anti-goals

- A web page squeezed into Tern. It follows Tern's own design guide
  (`guides/design.md`), so it looks like a built-in app.
- Handling tokens. Everything still goes through `qf`.
- Noise: no toasts or focus changes from background refreshes.

## Approaches

| Approach | Trade-off | Decision |
|---|---|---|
| **Grow the plugin's launches block** into a full-page app | Native look, every way of opening it, and the `qf` calls and URL code already exist | **Chosen** |
| A `qf ui` program in the Go CLI that speaks Tern's Surface Protocol | Works over SSH, but much more work for the same screen, and only Tern can draw it | Dropped |
| A canvas panel | Built for agents reporting progress, not for a view you browse | Dropped |

## The page

Following the design guide's app shell: head row, stats strip, then the view.
The block draws in the `sans` font.

```text
Qualflare  [app-landing ▾] · updated 1 min ago                  [Upload] [Refresh R]
Pass rate 94% │ Failed 6 │ Flaky 2 │ Last run 12 min ago
┌ launches table, full width ───────────────────┐ ┌ #128 · main · Staging ──────────────┐
│ #128  ✗ failed  main  Staging  ▓▓▓░ 94/100 12m│ │ 94 passed · 6 failed · 2 flaky       │
│ #127  ✓ passed  main  Staging  ▓▓▓▓ 100   1h  │ │ Risk: medium: checkout flow broken  │
│ …                                             │ │ Failing areas · Recommendations      │
└───────────────────────────────────────────────┘ │ [Open on website]  [Fix with omp]    │
                                                  └──────────────────────────────────────┘
↑↓ select · Enter open on website · R refresh · U upload · P project
```

- **Head row.** The project name is a menu of the logged-in `qf` projects
  (`qf projects`). The right side holds *Upload* (types `qf <id> collect
  <report dir>` into a terminal pane, as the palette command does) and
  *Refresh*.
- **Stats strip.** Four tiles from the latest launch: pass rate, failed
  (failed + error + timeout), flaky, and the age of the last run.
- **Table.** Recent launches, newest first: number, status badge, branch,
  environment, a pass/fail meter cell with counts, and age. Rows are selectable.
  The first page of `qf <id> launches list` only; a *Show more* row pages if
  `paging.pages > 1`.
- **Detail card** for the selected row:
  - its counts, framework, OS and browser, commit, and milestone, as a `kv`
    list;
  - the AI summary (`aiSummary`, a JSON string): the executive summary, the
    risk level as a badge with its justification, failing areas, and
    recommendations;
  - *Open on website* (the card's one primary action);
  - *Fix with omp*, shown only on failed launches; it starts omp on
    `/skill:qf-fix`, as the existing palette command does.
- **Dock.** A key legend.
- **Four states.** Loading uses skeleton rows. Empty: "No launches yet" with an
  *Upload* action. Error: the existing `qf` exit-code messages (not logged in
  shows the `qf login` hint, plan limit, not found, retry) with *Retry*. Success
  is the page above.
- **Refresh** every 60 s while the block is open (as now), plus `R`. A refresh
  keeps the selection by launch number.
- **Title**: `Qualflare · <project>`.

## How the tab opens

- **Palette:** "New Qualflare block" (from the manifest) and the existing
  *Qualflare: Show launches*, which now opens it as a tab.
- **Links:** a `tern.route.link` handler claims
  `https://app.qualflare.com/project/<slug>/launches…` links clicked in
  terminal panes. It opens the tab on that project with that launch selected,
  when the slug maps to a logged-in identifier (the `slugs` setting, or a slug
  equal to the identifier). Otherwise it passes. A setting, `route_links`,
  default on, turns this off. Links followed from inside the tab itself must
  not be claimed, or *Open on website* would loop back into the tab.
- **Project:** an explicit argument (from a link or the menu) wins. Otherwise
  the focused pane's project (`.qualflare/test-state.md`, as now). Otherwise
  the first logged-in project.

## Constraints

- Every handler has Tern's 2 s host budget, so `qf` runs through the
  asynchronous `tern.process.run`, as now.
- Saved state (the last result, the project and the selection) persists through
  `save`, so the tab comes back after a daemon restart without a blank load.
- Strict luau-lsp passes, and the existing test runner (`tests/run.luau`) covers
  the new view and route logic.

## Left to the builder

- How *Open on website* reaches Tern's browser block from a host block. If
  there's no clean way, fall back to `cx:open(url)` and let Tern decide.
- How the link route tells a terminal pane's click apart from one in the tab.
  The `link.pane` kind is the likely check.
- Exact column priorities and widths, and the meter cell's look.
- Whether the old split-pane layout of the launches block survives as anything
  other than this page. Proposal: it doesn't; one block, one page.
