# Qualflare pane v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the Qualflare pane around "is my latest run OK, is it getting better or worse, where should I look", with live refresh after uploads.

**Architecture:** Pure helpers in `lib/views.luau` (ages, deltas), the page in `lib/tab.luau` (verdict, trend, card, where-to-look), and state/IO in `host.luau` (clusters fetch, a registry of open panes refreshed by `command_finished`).

**Tech Stack:** Luau, Tern plugin API (`tern.ui`, `tern.process`, `tern.timer`), the `qf` CLI.

**Spec:** `docs/superpowers/specs/2026-11-16-qualflare-tab-design.md`, section "Version 2".

## Global Constraints

- Strict luau-lsp clean: `luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau`.
- Tests: `python3 tests/bundle.py .build/t.luau && luau .build/t.luau` (Luau 0.744 and luau-lsp 1.70.1 from their GitHub releases, on `PATH`).
- Never handle tokens; all data through `qf`. No server writes.
- Commits as `Qualflare Root <root@qualflare.com>`, no AI attribution.
- The plugin is linked live into the owner's Tern: keep every saved state loadable.

## Review Focus

1. A launch with `totalCount = 0` (or missing counts): verdict and trend must not divide by zero.
2. Only one launch: no trend, no "what changed" line, no crash indexing `launches[2]`.
3. An upload for project A must not refresh or reselect a pane showing project B, nor a closed pane.
4. The clusters call failing (exit 3, 5) or returning non-JSON hides "Where to look" without touching the launches error state.
5. Saved state from 0.2.0 (no `clusters`, no `fresh`) restores without errors.

---

### Task 1: Ages and deltas (`lib/views.luau`)

**Interfaces — Produces:**
- `views.ago(ts: any, now: number): string` — `just now` < 60 s, `N min ago` < 1 h, `N h ago` < 24 h, `N d ago` < 30 d, then `Mon D` (same UTC year as `now`) or `Mon D, YYYY`. Numbers stay `N d ago`.
- `views.days(ts: any, now: number): number?` — whole days since `ts`.
- `views.change(cur: any, prev: any): string` — `+2 tests · 4 more failing than #41`; parts omitted when zero; `Same counts as #41` when both are zero.

- [ ] Step 1: Update `views.ago buckets relative times`: 8 d → `8 d ago`; 40 d → `Oct 7`; 400 d → `Oct 12, 2025` (compute from the fixture date). Add `views.change` test: `{seq=42,totalCount=120,failedCount=7,errorCount=1}` vs `{seq=41,totalCount=118,failedCount=0}` → `+2 tests · 8 more failing than #41`; fewer → `3 fewer failing`; equal → `Same counts as #41`; `−` for fewer tests.
- [ ] Step 2: Run, expect FAIL.
- [ ] Step 3: Implement.
- [ ] Step 4: Run, expect PASS; luau-lsp clean.
- [ ] Step 5: Commit `feat: ages and run-to-run changes for the Qualflare pane`.

### Task 2: The page (`lib/tab.luau`)

**Interfaces — Consumes:** Task 1. **Produces:** `TabState` gains `clusters: { any }?` and `fresh: number?`; `tab.verdict(l: any, now: number): { tone: string, text: string }`.

- [ ] Step 1: Tests (replace the stats-strip assertions):
  - verdict of fixture `[1]` → tone `error`, text `✗ 8 of 120 failing · feat/checkout · staging · …`; of `[2]` alone → `✓ Latest run passed · 118 tests · staging · …`; `{status="running"}` → starts `● Latest run running`; `{totalCount=0}` doesn't error.
  - page shows the change line `than #41`, a `chart` node (kind list), no `Pass rate` tile.
  - a single launch: no `chart`, no `than #`.
  - newest older than 7 days → `No runs in 8 days`.
  - card: status badge at head end (`end` prop set), no `no branch`, recommendations rendered as text (not `list`), no `test_summary`.
  - clusters `{CLUSTERS}` with failing newest → `Where to look` and the cluster label; passing newest → no `Where to look`.
  - `fresh = 42` → text `new`.
  - launches row has `wrap = true`.
- [ ] Step 2: Run, expect FAIL.
- [ ] Step 3: Implement per spec items 1–4 and 6 (`ui.node("chart", {kind="bars", size="sm", min=0, max=100, series, summary})`; clusters through `views.clusters_table` with at most 3 items).
- [ ] Step 4: Run, expect PASS; luau-lsp clean.
- [ ] Step 5: Commit `feat: verdict, trend and where-to-look in the Qualflare pane`.

### Task 3: Clusters fetch and live refresh (`host.luau`)

**Interfaces — Consumes:** Task 2 state fields.

- [ ] Step 1: Tests:
  - refresh with a failing newest launch runs `qf demo-app clusters list --sort-by lastSeenAt --sort-desc` and stores 3 at most; passing newest → no clusters call and `clusters = nil`; clusters exit 3 → `clusters = nil`, `error` still nil.
  - `activate`/action `cluster=7` from the block opens `…/clusters/7&src=tern`-style own URL.
  - `command_finished` `qf demo-app collect r.xml` status 0 → the open demo-app pane re-runs `launches list`, selects the new top seq, `fresh` set; a `web` pane and a closed pane are not refreshed; status 1 → nothing.
  - top seq unchanged after the upload refresh → one 5 s timer retry.
  - `init` with 0.2.0-shaped `saved` works.
- [ ] Step 2: Run, expect FAIL.
- [ ] Step 3: Implement: module `live: { [number]: { s, cx } }` filled in `init`, pruned when `running` is false; `on_upload(identifier)` called from the `command_finished` hook on success.
- [ ] Step 4: Run, expect PASS; luau-lsp clean.
- [ ] Step 5: Commit `feat: refresh Qualflare panes after uploads and show failure clusters`.

### Task 4: Docs and version

- [ ] README "Qualflare pane" section describes the verdict, trend, where-to-look and live refresh; `plugin.toml` version `0.3.0`; `tern plugin reload` exits 0.
- [ ] Commit `docs: Qualflare pane version 2`.
