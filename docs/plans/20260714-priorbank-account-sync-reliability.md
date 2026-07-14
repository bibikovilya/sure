# Priorbank Account Sync Reliability: Stagger + Retry on Connection Timeout

## Problem

When a `PriorbankItem` sync completes, it enqueues all linked account `SyncJob`s simultaneously.
With 7 accounts all starting at once and `RAILS_MAX_THREADS=3` (pool=3, Sidekiq concurrency=3),
the DB connection pool is exhausted and one account sync fails with:

```
could not obtain a connection from the pool within 5.000 seconds; all pooled connections were in use
```

## Solution Overview

Two complementary fixes, both localized to Priorbank code (no changes to global `Sync` model):

1. **Stagger enqueuing** — spread account `SyncJob`s 5 seconds apart so at most 1–2 run
   concurrently, well within pool=3.

2. **Retry inside `PriorbankAccount::Syncer#perform_sync`** — if a timeout still occurs
   (e.g. under load), retry up to 2 times with exponential backoff (2s, 4s) before raising.
   Kept inside the syncer so the `Sync` state machine in `sync.rb` is not affected.

## Implementation Steps

### Task 1: Stagger account sync enqueuing in `download_statements`

**File:** `app/models/priorbank_item/syncer.rb`

- [x] Change `SyncJob.perform_later(account_sync)` to
      `SyncJob.set(wait: index * 5.seconds).perform_later(account_sync)` using the loop index
      from `downloads.each_with_index`

### Task 2: Rescue `ConnectionTimeoutError` inside `PriorbankAccount::Syncer#perform_sync`

**File:** `app/models/priorbank_account/syncer.rb`

- [x] Wrap the `perform_sync` body in a `begin/rescue/retry` block
- [x] Rescue `ActiveRecord::ConnectionTimeoutError`, increment a `retries` counter, raise after
      3 attempts, otherwise `sleep(2 ** retries)` and `retry`

### Task 3: Verify

- [x] Run `bin/rails test` — full suite must pass
- [x] Run `bin/rubocop -f github -a` — no new offenses
- [x] Run `bin/brakeman --no-pager` — no new warnings
- [ ] Trigger a real item sync and confirm all account syncs complete without pool errors
- [ ] Move this plan to `docs/plans/completed/`
