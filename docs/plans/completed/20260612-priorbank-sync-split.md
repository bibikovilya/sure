# Priorbank Sync Split: Item Sync Owns Browser, Account Syncs Run Independently

## Overview

Refactor the PriorbankItem/Account sync lifecycle so the item sync owns the
entire browser session (login → extract account details → download all CSVs),
marks itself completed, then enqueues independent PriorbankAccount syncs.

**Problems solved:**
- Item sync currently waits for all child account syncs to finish before
  marking itself complete — the UI treats the browser phase and the CSV
  processing phase as one monolithic operation.
- Per-account CSV download failures are silently swallowed — the item sync
  completes even if some accounts got no data.
- `finalize_if_all_children_finalized` calls `perform_post_sync` on an
  already-completed parent, which is semantically wrong and causes noise.

**Result:**
- Item sync status = "browser session complete, account syncs queued".
- Each account sync runs and completes fully independently.
- Parent-child relationship is kept (hierarchy display in UI), but the parent
  does NOT wait for children to finalize itself.
- Any CSV download failure aborts the whole item sync (fail-fast).

## Context (from discovery)

- **Files involved:** `app/models/priorbank_item/syncer.rb`,
  `app/models/sync.rb`, `test/models/priorbank_item/syncer_test.rb`
- **Pattern:** `Sync#finalize_if_all_children_finalized` currently drives
  completion for all syncs — the `if syncing?` guard already prevents
  double `complete!`, but `perform_post_sync` still runs on already-terminal
  parents when children propagate upward.
- **Dependency:** `SyncJob` always calls `finalize_if_all_children_finalized`
  in its ensure block after `perform_sync` returns.

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to the next
- All tests must pass before starting the next task

## Solution Overview

### `Sync#finalize_if_all_children_finalized` — add `return unless syncing?`

Currently:
```ruby
if syncing?
  complete! or fail!
end
perform_post_sync  # ← runs even on already-completed parent
parent&.finalize_if_all_children_finalized
```

After:
```ruby
return unless syncing?   # ← new guard; no-op if already terminal
complete! or fail!
perform_post_sync
parent&.finalize_if_all_children_finalized (outside transaction)
```

### `PriorbankItem::Syncer#perform_sync` — complete itself

```ruby
def perform_sync(sync)
  fetched_accounts = fetch_accounts_from_priorbank(sync)
  import_accounts(fetched_accounts, sync)
  sync.complete!
  sync.parent&.finalize_if_all_children_finalized  # notify family sync
rescue => e
  mark_failed(sync, e)
end
```

### `download_statements` — two-phase, fail-fast

Phase 1: download all CSVs (no rescue — first failure aborts the loop).
Phase 2: only reached if all downloads succeeded → create all account syncs
and enqueue SyncJobs atomically.

## Implementation Steps

### Task 1: Guard `Sync#finalize_if_all_children_finalized` against already-terminal syncs

**Files:**
- Modify: `app/models/sync.rb`

- [ ] Replace the `if syncing? ... end; perform_post_sync` block with
      `return unless syncing?` at the top, then unconditional `complete!`/`fail!`
      and `perform_post_sync`
- [ ] Verify the method still calls `parent&.finalize_if_all_children_finalized`
      outside the transaction block (unchanged)
- [ ] Write test: calling `finalize_if_all_children_finalized` on a completed
      sync is a no-op (no state change, no `perform_post_sync` call)
- [ ] Write test: calling it on a failed sync is also a no-op
- [ ] Run `bin/rails test test/models/sync_test.rb` — must pass

### Task 2: Item syncer completes itself and notifies parent

**Files:**
- Modify: `app/models/priorbank_item/syncer.rb`

- [ ] In `perform_sync`, after `import_accounts`, add `sync.complete!`
- [ ] After `sync.complete!`, add `sync.parent&.finalize_if_all_children_finalized`
      so a parent family sync is notified when browser work is done
- [ ] Remove the comment that says "Do not call complete! here" (now outdated)
- [ ] Keep `mark_failed` rescue unchanged

### Task 3: Make `download_statements` fail-fast and atomically enqueue

**Files:**
- Modify: `app/models/priorbank_item/syncer.rb`

- [ ] Rewrite `download_statements` as two phases:
  - Phase 1: iterate all linked accounts, call `downloader.call` with no rescue
    — store `{ account => { csv_path:, window: } }` in a hash.
    Any failure propagates immediately (no more per-account rescue).
  - Phase 2 (only if phase 1 completes): mark stale, create Sync records
    with `parent: item_sync`, and enqueue `SyncJob` for each account.
- [ ] Remove the `sync_update` log lines that were specific to per-account
      error recovery ("Warning: Failed to download statement for...")
- [ ] Keep `sync_update` progress messages for downloads in progress and success

### Task 4: Update tests

**Files:**
- Modify: `test/models/priorbank_item/syncer_test.rb`

- [ ] Update `perform_sync` test: assert `item_sync.reload.completed?` (was
      `assert_not_equal "failed"`)
- [ ] Remove "continues to next account when one fails" test — behavior has
      changed to fail-fast
- [ ] Remove "logs warning on per-account failure without aborting" test
- [ ] Add test: `download_statements` raises (propagates) when any account
      download fails, leaving zero account Sync records created
- [ ] Add test: all account syncs are created only after all downloads succeed
      (phase-2 atomicity)
- [ ] Update existing `download_statements` tests to remove expectations
      about per-account error recovery
- [ ] Run `bin/rails test test/models/priorbank_item/` — must pass

### Task 5: Verify acceptance criteria

- [ ] Run full test suite: `bin/rails test`
- [ ] Trigger a real PriorbankItem sync in development and confirm:
  - Item sync moves to `completed` once browser session finishes
  - Account syncs appear as children in the hierarchy section
  - Account syncs run and complete independently
  - Item sync modal shows no account-level steps
- [ ] Run `bin/rubocop -f github -a` and fix any offenses
- [ ] Run `bundle exec erb_lint ./app/**/*.erb -a`

### Task 6: Move plan to completed

- [ ] `mkdir -p docs/plans/completed && mv docs/plans/20260612-priorbank-sync-split.md docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Open `/priorbank_items` and trigger a sync — verify item sync completes
  before account syncs finish.
- Verify the hierarchy section of the item sync modal lists account syncs
  as children.
- Verify a fresh sync after a prior failure clears the "Requires
  re-authentication" warning as expected.
