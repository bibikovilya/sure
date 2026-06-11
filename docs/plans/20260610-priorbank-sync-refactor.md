# Priorbank Sync Refactor

## Overview

Consolidate all browser automation into a single session per `PriorbankItem` sync, and replace fragile navigation patterns with robust retry logic. Currently each `PriorbankAccount::Syncer` spawns its own browser session (login → navigate → download CSV), so N accounts = N full browser launches. A single bad navigation also blocks Sidekiq for 5 minutes via a hardcoded sleep.

**After this refactor:**
- `PriorbankItem::Syncer` owns the entire browser lifecycle: login once, discover accounts, download all CSVs, close browser
- `PriorbankAccount::Syncer` becomes a pure CSV parser + importer with zero browser dependency
- Account syncs are auto-triggered by the item sync (no separate per-account sync button)
- `Priorbank::BrowserSession` uses exponential-backoff retry and `wait_for_idle` instead of hardcoded sleeps

## Context (from discovery)

- **Key files:**
  - `app/models/priorbank/browser_session.rb` — headless Chrome via Ferrum
  - `app/models/priorbank_item/syncer.rb` — discovers accounts (has the `sleep(5.minutes)` killer)
  - `app/models/priorbank_account/statement_downloader.rb` — creates its own BrowserSession (the duplication)
  - `app/models/priorbank_account/syncer.rb` — orchestrates per-account sync
  - `app/controllers/priorbank_accounts_controller.rb` — per-account sync trigger (to be removed)
- **Critical bug:** `sleep(5.minutes)` in `PriorbankItem::Syncer#extract_card_data` line 104 blocks Sidekiq workers
- **Root cause of fragility:** CSS selectors, hardcoded Cyrillic text, and sequential sleeps with no retry logic
- **Handoff mechanism:** new `pending_csv_path` column on `priorbank_accounts`; item syncer writes, account syncer reads + clears

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- Every task that changes behavior must include updated tests
- All tests must pass before starting the next task
- Do not run migrations automatically — note where they're needed

## Testing Strategy

- Unit tests: `Priorbank::BrowserSession` retry helper, `PriorbankAccount::Syncer` CSV-only path, `PriorbankItem::Syncer` CSV download orchestration
- Browser navigation tests are not unit-testable; manual verification is covered in Post-Completion
- Existing `csv_parser_test.rb` and `transaction_builder_test.rb` should require no changes

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix

## Solution Overview

```
PriorbankItem::Syncer (one browser session)
  ├── login_and_navigate_to_cards                  [existing]
  ├── load linked accounts from DB                 [replaces extract_card_data in regular sync]
  ├── download_csv_for_each_linked_account         [NEW — calls StatementDownloader with shared session]
  │     └── saves path → sync.data["csv_path"] on account's Sync record
  └── perform_post_sync
        └── triggers SyncJob per linked account    [NEW]

Note: extract_card_data (browser-based card scraping) is kept for the
initial connection setup flow only. Regular sync reads linked accounts
from DB via priorbank_item.priorbank_accounts.joins(:account_provider).

PriorbankAccount::Syncer (no browser)
  ├── reads sync.data["csv_path"]                  [replaces StatementDownloader call]
  ├── fixes encoding, parses CSV, imports
  └── file kept on disk for history

Priorbank::BrowserSession (robustness)
  ├── with_retry(attempts:, backoff:) helper       [NEW]
  ├── all sleeps replaced with wait_for_idle/wait_for
  └── close_popups handles multiple popup types
```

## Technical Details

- **CSV path storage**: stored in `sync.data["csv_path"]` on the account's `Sync` record — no new column needed on `priorbank_accounts`. The `Sync` model's existing `data` JSONB already stores operational state (window dates, stats, etc.); `csv_path` fits naturally there
- **CSV file lifecycle**: downloaded to `Dir.mktmpdir` by item syncer, path written to `sync.data["csv_path"]`; files are kept on disk after parsing for historical reference (not deleted)
- **Account sync trigger**: `PriorbankItem::Syncer#perform_post_sync` creates a `Sync` record per linked account (with `data: { csv_path: path }`), then enqueues `SyncJob` with that sync_id; account syncer reads `sync.data["csv_path"]`
- **Backoff formula**: `delay = base_delay * (2 ** attempt)` — e.g. attempts 1/2/3 wait 1s/2s/4s before retry
- **StatementDownloader** keeps its public interface but gains a `session:` keyword arg; when a session is passed it skips login/navigation and only does the card-specific steps

## What Goes Where

**Implementation Steps** — all achievable in this codebase.

**Post-Completion** — manual browser testing against live Priorbank site.

---

## Implementation Steps

### Task 1: Add `with_retry` helper to BrowserSession and remove hardcoded sleeps

Eliminate the `sleep(5.minutes)` blocker and all gratuitous fixed sleeps. Replace with a reusable `with_retry` helper and `wait_for_idle` calls.

**Files:**
- Modify: `app/models/priorbank/browser_session.rb`
- Modify: `app/models/priorbank_item/syncer.rb`

- [x] Add private `with_retry(attempts: 3, base_delay: 1, &block)` to `Priorbank::BrowserSession` that catches `StandardError`, sleeps `base_delay * 2**attempt` between retries, re-raises after final attempt
- [x] In `BrowserSession#login_to_priorbank`: replace `sleep(1)`, `sleep(2)`, `sleep(0.5)`, `sleep(0.2)` with `page.network.wait_for_idle(timeout:)` calls; keep only the field-focus micro-sleeps (≤0.1s) that are genuinely needed for CDP events
- [x] In `BrowserSession#open_cards_page`: replace the manual 10-attempt loop with `with_retry(attempts: 5, base_delay: 1)` wrapping the navigation block; remove `sleep(0.5)` and `sleep(0.3)` inside
- [x] In `BrowserSession#wait_for_page_ready`: replace `sleep(1)` at end with `page.network.wait_for_idle(timeout: 5) rescue nil`
- [x] In `PriorbankItem::Syncer#extract_card_data`: remove `sleep(5.minutes)` (line 104) — on card extraction failure, use `with_retry` retry logic or log + continue to next card without blocking
- [x] In `PriorbankItem::Syncer#extract_card_data`: replace `sleep(0.3)`, `sleep(0.5)` with `wait_for` calls on the next expected element
- [x] Move browser timeouts to named constants inside `Priorbank::BrowserSession`: `BROWSER_TIMEOUT = 30` and `PROCESS_TIMEOUT = 60`
- [x] Write tests for `with_retry`: verify it retries on error, waits between attempts, re-raises after max attempts, returns block value on success
- [x] Run tests: `bin/rails test test/models/priorbank_account/` — must pass before Task 2

---

### Task 2: Improve popup handling and navigation resilience in BrowserSession

Make `close_popups` handle multiple popup types and re-check after each close. Ensure navigation doesn't silently swallow failures.

**Files:**
- Modify: `app/models/priorbank/browser_session.rb`

- [x] Rewrite `close_popups` to check three selectors: `div.k-widget.k-window`, `div.modal`, `[role="dialog"]`; close all visible ones in a loop until none remain or max 5 iterations
- [x] After `submit_button.click` in `login_to_priorbank`: use `with_retry` to wait for title == "Рабочий стол" instead of `sleep(2)` + one-shot title check
- [x] In `open_cards_page`: call `close_popups` before clicking menu items (already partially done), add `wait_for_idle` after each menu click instead of `sleep(0.3)`
- [x] Add `screenshot_on_failure(label)` public helper: saves to `Rails.root/tmp/priorbank-<label>-<timestamp>.png`; use it in `with_retry`'s rescue block on final failure
- [x] Update `BrowserSession#wait_for` to log a warning (not silent) when it times out without finding the selector
- [x] Run tests: `bin/rails test test/models/priorbank_account/` — must pass before Task 3

---

### Task 3: No schema migration needed

The CSV path is stored in `sync.data["csv_path"]` on the account's `Sync` record. The `Sync` model already has a `data` JSONB column — no new columns or migrations are required.

**Files:** none

- [x] Confirm that `Sync#data` is a JSONB column (check schema): `grep -A5 "create_table.*syncs" db/schema.rb`
- [x] Confirm that `sync.data = sync.data.merge(csv_path: path)` + `sync.save!` round-trips correctly (no unexpected serialization)
- [x] No migration to run — proceed to Task 4

---

### Task 4: Refactor `StatementDownloader` to accept an existing browser session

Decouple CSV download logic from browser session management so it can participate in a shared session.

**Files:**
- Modify: `app/models/priorbank_account/statement_downloader.rb`

- [x] Add `session:` keyword argument to `initialize`; when provided, skip `BrowserSession.new` and use the passed session instead
- [x] Extract `owns_session` boolean flag: `true` when session was self-created (backward-compat path), `false` when injected
- [x] In `call`: skip `session.login_and_navigate_to_cards` when `owns_session == false` (caller already navigated)
- [x] In `ensure` block of `call` (and `teardown`): only call `session.quit` when `owns_session == true`
- [x] Verify backward-compat: calling `StatementDownloader.new(...)` without `session:` still works end-to-end (same as before)
- [x] Write tests for the injected-session path: stub a session double, verify `login_and_navigate_to_cards` is NOT called, verify `session.quit` is NOT called
- [x] Run tests: `bin/rails test test/models/priorbank_account/` — must pass before Task 5

---

### Task 5: Extract per-account sync window calculation to `PriorbankAccount`

The date window (start/end dates for the statement download) is currently calculated inside `PriorbankAccount::Syncer`. Move it to `PriorbankAccount` itself so both the item syncer and the account syncer can ask each account "what date range do you need?" before touching the browser filter.

**Files:**
- Modify: `app/models/priorbank_account.rb`
- Modify: `app/models/priorbank_account/syncer.rb`

- [x] Add `sync_window` instance method to `PriorbankAccount` returning `{ start_date:, end_date: }` using the same logic as the current `PriorbankAccount::Syncer#calculate_window_start`: last completed sync's `window_end_date` → latest entry date → 3 months ago fallback; `end_date` defaults to `Date.current`
- [x] Remove the duplicated `calculate_window_start` private method from `PriorbankAccount::Syncer`; replace its usages with `priorbank_account.sync_window[:start_date]` and `priorbank_account.sync_window[:end_date]`
- [x] Write tests for `PriorbankAccount#sync_window`: no syncs + no entries → 3 months ago, with prior completed sync → uses its `window_end_date`, with entries but no sync → uses latest entry date
- [x] Run tests: `bin/rails test test/models/priorbank_account/` — must pass before Task 6

---

### Task 6: Extend `PriorbankItem::Syncer` to download all CSVs in the same session

After account discovery, stay in the open browser session and download a CSV for every **linked** account, using that account's own `sync_window` dates for the browser date filter.

**Files:**
- Modify: `app/models/priorbank_item/syncer.rb`

- [x] Add private `download_statements(session, item_sync)` method that iterates `priorbank_item.priorbank_accounts.joins(:account_provider)` and for each:
  - calls `account.sync_window` to get `{ start_date:, end_date: }`
  - creates `StatementDownloader.new(start_date, end_date, account.name, session: session, sync: item_sync)`
  - calls `.call` to get the CSV path
  - creates an account `Sync` record with `data: { csv_path: path }` (status: `:pending`) — do NOT enqueue the job yet; that's `perform_post_sync`'s job
- [x] Call `download_statements(session, sync)` inside `fetch_accounts_from_priorbank` AFTER `extract_card_data` and BEFORE `session.quit` in the `ensure` block — session must still be open
- [x] On per-account download failure: log warning + `sync_update` + continue to next account (do not abort the whole item sync)
- [x] Add per-account progress updates: `"Downloading statement for '#{account.name}' (#{start_date}–#{end_date})..."`
- [x] Write tests: stub `BrowserSession`, verify `StatementDownloader` receives the correct per-account start/end dates and the shared `session:`, verify account `Sync` record is created with `data["csv_path"]` set, verify one account's failure doesn't abort others
- [x] Run tests: `bin/rails test test/models/priorbank_account/` + `bin/rails test test/models/priorbank_item/` if exists — must pass before Task 7

---

### Task 7: Simplify `PriorbankAccount::Syncer` — remove browser dependency

Replace the `StatementDownloader` call (which created its own browser) with a direct read from `sync.data["csv_path"]`.

**Files:**
- Modify: `app/models/priorbank_account/syncer.rb`

- [x] Replace `fetch_transactions` implementation: read `sync.data["csv_path"]`, raise a descriptive error if nil or file doesn't exist on disk (`"No statement CSV found in sync data — run a full Priorbank item sync first"`)
- [x] Remove `downloader.teardown` call (no longer owns a download path or browser)
- [x] Remove the `StatementDownloader` instantiation and `login:`, `password:` args entirely
- [x] CSV file is NOT deleted after parsing — kept on disk for historical reference
- [x] Update `syncer_test.rb`: remove all stubs for `StatementDownloader` and `BrowserSession`; instead build a `Sync` record with `data: { "csv_path" => fixture_csv_path }` before calling `perform_sync`
- [x] Write test for missing `csv_path` in sync data: verify `perform_sync` raises a clear error and marks sync as failed
- [x] Run tests: `bin/rails test test/models/priorbank_account/syncer_test.rb` — must pass before Task 8

---

### Task 8: Wire `Family::Syncer` to sync at item level + trigger account syncs via `perform_post_sync`

Currently `Family::Syncer` maps priorbank items → individual accounts (`map(&:linked_priorbank_accounts).flatten`), calling `sync_later` on each account directly. Flip this: sync at the item level so one browser session covers all linked accounts. Then `PriorbankItem::Syncer#perform_post_sync` triggers the account-level syncs after CSVs are ready.

**Files:**
- Modify: `app/models/family/syncer.rb`
- Modify: `app/models/priorbank_item/syncer.rb`

- [ ] In `Family::Syncer#child_syncables`: replace `family.priorbank_items.active.map(&:linked_priorbank_accounts).flatten` with `family.priorbank_items.active` so item syncs are scheduled (not individual account syncs)
- [ ] Implement `PriorbankItem::Syncer#perform_post_sync`: find each account's pending `Sync` record (status `:pending` with `data["csv_path"]` present), enqueue `SyncJob.perform_later(sync.id)` for each — do NOT create new sync records here, they were already created in `download_statements`
- [ ] Ensure idempotency: skip accounts whose pending sync record doesn't have `data["csv_path"]` or is already running/completed
- [ ] Write test for `Family::Syncer#child_syncables`: verify priorbank items (not accounts) are included
- [ ] Write test for `PriorbankItem::Syncer#perform_post_sync`: verify `SyncJob` is enqueued for pending sync records with csv_path, skipped for accounts without pending csv syncs
- [ ] Run tests: `bin/rails test` — must pass before Task 9

---

### Task 9: Keep manual per-account sync intact

The automated path now goes through `Family::Syncer` → item sync → account syncs. The manual per-account sync (controller + UI button) stays as-is for on-demand use — no changes needed here.

**Files:** none

- [ ] Verify `PriorbankAccountsController#sync` still works end-to-end in manual mode: the controller creates a `Sync` record and enqueues the job; the account syncer then reads `sync.data["csv_path"]` and fails with a clear error if absent
- [ ] The clear error message (`"No statement CSV found in sync data — run a full Priorbank item sync first"`) is already set in Task 7 — confirm it's in place
- [ ] Run tests: `bin/rails test` — must pass before Task 10

---

### Task 10: Verify acceptance criteria and final cleanup

- [ ] All requirements from Overview are implemented: single browser session per item sync, account syncers have no browser dependency, retry with exponential backoff, no hardcoded `sleep` > 0.5s remaining
- [ ] Edge case: PriorbankItem with 0 linked accounts — item sync completes gracefully
- [ ] Edge case: PriorbankItem has accounts but none are linked to an app Account yet — CSV download is skipped, account syncs are not triggered
- [ ] Edge case: one account's CSV download fails — other accounts still get their CSVs and their syncs are triggered
- [ ] Edge case: `pending_csv_path` temp file is missing when account sync runs — sync fails with a clear error message
- [ ] Run full test suite: `bin/rails test`
- [ ] Run linter: `bin/rubocop -f github -a`
- [ ] Run security check: `bin/brakeman --no-pager`
- [ ] Move this plan to `docs/plans/completed/`

---

## Post-Completion

**Manual browser testing** (requires live Priorbank access):
- Run item sync end-to-end; verify single browser launch in process list
- Verify all cards' CSVs are downloaded and account syncs enqueue automatically
- Trigger item sync when Priorbank shows a popup on login; verify popup is closed and sync continues
- Test with wrong credentials; verify `requires_update` status set, no Sidekiq worker blocked
- Check `tmp/priorbank-*.png` screenshots exist on navigation failures

**Monitoring:**
- After deploy, watch Sidekiq dashboard — confirm no workers stuck waiting
- Verify `pending_csv_path` columns are cleared after account syncs complete (no orphaned temp files)
