# Priorbank v0.7.2 Upgrade

## Overview

Upgrade the Priorbank integration to align with upstream v0.7.2, covering four sequential
phases: merge upstream changes, remove the obsolete manual import path, integrate automatic
CSV storage into the Statement Vault (encoding already handled by existing `CsvEncodingFixer`),
and rewrite the Priorbank UI to use the new bank sync design system.

Each phase depends on the previous one — the UI and Statement Vault work both require v0.7.2
infrastructure that doesn't exist on the current branch.

## Context (from discovery)

- **Current branch**: `main` at v0.6.6-ib.6; upstream (`we-promise`) at v0.7.2
- **Priorbank models**: `app/models/priorbank_item/syncer.rb`, `app/models/priorbank_account/syncer.rb`, `csv_parser.rb`, `statement_downloader.rb`, `transaction_builder.rb`
- **Priorbank views**: `app/views/priorbank_items/`, `app/views/priorbank_accounts/`
- **TransactionPriorImport**: manual-upload-only, never referenced by auto-sync; safe to remove
- **Encoding**: already handled by `Utils::CsvEncodingFixer.convert_file` in `PriorbankAccount::Syncer#fetch_transactions` (lines 65-83); `CsvParser#parse` already receives a UTF-8 string — no refactor needed
- **Statement Vault**: introduced in v0.7.1 — `AccountStatement` model with Active Storage, SHA256 dedup, `create_from_upload!` class method. Exact API to be verified after Phase 1 merge.
- **New UI pattern**: `DS::Disclosure` card, sync-summary component, accounts grouped by type. Component names to be confirmed after Phase 1 merge (they do not exist yet on this branch).
- **`PriorbankAccount` accessors**: delegates `family` (via `priorbank_item`), exposes `account` via `has_one :account, through: :account_provider`, no `account_number` attribute — use `name` for filenames

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each phase fully before moving to the next
- All tests must pass before starting the next phase
- Phases 2–4 can only be implemented after Phase 1 (merge) is complete

## Testing Strategy

- **Unit tests**: Minitest fixtures (no RSpec, no factories)
- **System tests**: not required for this work
- **View tests**: Phase 4 is view-only changes; no automated tests — verified manually in browser (per CLAUDE.md guidance)
- Run `bin/rails test` after each phase
- Run `bin/rubocop -f github -a` and `bin/brakeman --no-pager` before PR

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document blockers with ⚠️ prefix

## Solution Overview

1. Merge upstream v0.7.2 into a feature branch, resolving conflicts in sync infrastructure, views, and Gemfile
2. Remove `TransactionPriorImport` and its supporting files (including the `transaction_prior` fixture) — it was a backfill tool; Statement Vault covers the "store statements" use case going forward
3. Hook `AccountStatement.create_from_upload!` into `PriorbankAccount::Syncer` — reuse the already-fixed `fixed_csv_data` string from `fetch_transactions`, wrap in `StringIO`, save to vault before parsing. No changes to `CsvParser`.
4. Rewrite Priorbank views to use the new `DS::Disclosure` pattern and upstream sync-summary component, dropping the separate `sync_details` page in favour of inline stats

## Implementation Steps

---

### Phase 1: Merge upstream v0.7.2

**Files:** Resolved via git merge — no specific files listed (all conflicts)

- [ ] `git fetch we-promise --tags`
- [ ] `git checkout -b chore/merge-upstream-v0.7.2`
- [ ] `git merge v0.7.2 --no-ff -m "Merge upstream v0.7.2"`
- [ ] Resolve conflicts — priority order:
  - `Gemfile` / `Gemfile.lock` — keep upstream gems, keep Ferrum
  - `db/schema.rb` — accept upstream (adds `account_statements` table and others)
  - `app/models/sync.rb`, `app/models/concerns/syncable.rb` — accept upstream, verify Priorbank hooks still work
  - `app/models/account_provider.rb` — accept upstream, verify polymorphic bridge still maps to `PriorbankAdapter`
  - Version files (`version.rb`, `Chart.yaml`) — keep fork version string
  - Any other Priorbank-specific files — always keep fork side
- [ ] `bin/rails db:migrate` (new migrations from v0.7.2 including `account_statements`)
- [ ] `bin/rails test` — must pass (or identify which failures are merge artefacts to fix)
- [ ] Fix any remaining failures from API/interface changes in upstream sync infrastructure
- [ ] `bin/rubocop -f github -a`
- [ ] Commit resolved merge
- [ ] Confirm exact class/constructor for the new sync-summary component and the account-groups partial shipped in v0.7.2 (needed for Phase 4)
- [ ] Confirm `AccountStatement.create_from_upload!` signature (needed for Phase 3)

---

### Phase 2: Remove TransactionPriorImport

**Files:**
- Delete: `app/models/transaction_prior_import.rb`
- Delete: `app/views/import/configurations/_transaction_prior_import.html.erb`
- Delete: `test/models/transaction_prior_import_test.rb`
- Modify: `test/fixtures/imports.yml` — remove `transaction_prior` fixture entry (type: TransactionPriorImport)
- Modify: `app/models/import.rb` — remove `"TransactionPriorImport"` from TYPES array
- Modify: `app/helpers/imports_helper.rb` — remove from `permitted_import_types`
- Modify: `app/views/imports/new.html.erb` — remove TransactionPriorImport button/conditional (~lines 48-50)
- Modify: `app/views/import/uploads/show.html.erb` — edit the compound `||` conditionals at lines ~24 and ~56 (they also cover other import types — edit carefully, don't delete the entire branch)

- [ ] Delete the three files: model, view partial, test file
- [ ] Remove `transaction_prior` fixture from `test/fixtures/imports.yml` (no tests reference `imports(:transaction_prior)` directly)
- [ ] Remove `"TransactionPriorImport"` from `Import::TYPES` in `app/models/import.rb`
- [ ] Remove from `permitted_import_types` in `app/helpers/imports_helper.rb`
- [ ] Edit `app/views/imports/new.html.erb` lines ~48-50 (remove TransactionPriorImport button/conditional only)
- [ ] Edit `app/views/import/uploads/show.html.erb` lines ~24 and ~56 — remove `TransactionPriorImport` from the compound `||` conditions, keep other import type references intact
- [ ] Remove the stale comment at `app/models/priorbank_account/csv_parser.rb:36` ("Class method to allow reuse in TransactionPriorImport"); the `extract_transaction_lines` class method itself stays (still used internally by `parse`)
- [ ] `bin/rails test` — must pass
- [ ] `bin/rubocop -f github -a`

---

### Phase 3: Statement Vault integration in PriorbankAccount::Syncer

**Files:**
- Modify: `app/models/priorbank_account/syncer.rb`

The encoding fix is **already done** by `Utils::CsvEncodingFixer.convert_file` in `fetch_transactions`
(lines 65-83), which returns a clean UTF-8 string `fixed_csv_data`. The only new work is saving
that string to the vault before parsing. No changes to `CsvParser`.

Verify `AccountStatement.create_from_upload!` signature from Phase 1, then add after
`fetch_transactions` returns, before `parse_csv`:

```ruby
# Save fixed CSV to Statement Vault (SHA256 dedup prevents double-storage on re-sync)
vault_file = StringIO.new(fixed_csv_data)
account_name = priorbank_account.name
vault_file.define_singleton_method(:original_filename) do
  "priorbank_#{account_name}_#{sync.window_end_date}.csv"
end
vault_file.define_singleton_method(:content_type) { "text/csv" }

begin
  AccountStatement.create_from_upload!(
    family: priorbank_account.family,
    account: priorbank_account.account,
    file: vault_file
  )
rescue AccountStatement::DuplicateUploadError
  # normal on re-sync of same period — already stored
end
```

Note: If `create_from_upload!` accepts raw content + filename directly (confirm in Phase 1),
use that instead of the `StringIO` + singleton-method approach.

- [ ] Add Statement Vault call in `PriorbankAccount::Syncer#perform_sync` using `fixed_csv_data` (from `fetch_transactions`) — do NOT re-read or re-encode the file
- [ ] Use `priorbank_account.family` and `priorbank_account.account` (delegated accessors — no chaining via `priorbank_item` or `account_provider`)
- [ ] Add `rescue AccountStatement::DuplicateUploadError` guard
- [ ] Add a sync progress step entry for vault storage (e.g., `"statement_vault"`)
- [ ] Write test: syncer stores a statement in `AccountStatement` after sync (assert record created, blob attached and UTF-8 readable)
- [ ] Write test: duplicate CSV on re-sync does not raise — vault call skipped gracefully
- [ ] `bin/rails test` — must pass
- [ ] `bin/rubocop -f github -a`

---

### Phase 4: Priorbank UI rewrite (new bank sync UI pattern)

**Note:** Component and partial names below are tentative — confirmed names come from Phase 1.

**Files:**
- Modify: `app/views/priorbank_items/_priorbank_item.html.erb` — rewrite as `DS::Disclosure` card
- Delete: `app/views/priorbank_items/_priorbank_account.html.erb` — replaced by shared account-groups partial
- Delete: `app/views/priorbank_items/sync_details.html.erb` — replaced by inline sync-summary component
- Delete: `app/views/priorbank_items/_sync_details_dialog.html.erb` — no longer needed
- Delete: `app/views/priorbank_accounts/sync_details.html.erb` — inline in card
- Delete: `app/views/priorbank_accounts/_sync_details_dialog.html.erb` — inline in card
- Modify: `app/views/priorbank_accounts/link.html.erb` — update to `DS::Dialog` if API changed
- Modify: `app/controllers/priorbank_items_controller.rb` — remove `sync_details` action
- Modify: `app/controllers/priorbank_accounts_controller.rb` — remove `sync_details` action
- Modify: `config/routes.rb` — remove `sync_details` member routes from both resources

New `_priorbank_item.html.erb` structure (mirror Enable Banking pattern):
```erb
<DS::Disclosure variant: :card, open: true>
  summary: chevron + Priorbank logo + name + status badge (syncing/requires_update/last synced) + sync button + delete button
  body:
    - linked accounts grouped by type (via shared account-groups partial)
    - inline sync-summary component (stats: accounts, transactions, errors)
    - "link account" prompt for any unlinked PriorbankAccount records
</DS::Disclosure>
```

- [ ] After Phase 1: confirm exact component class name for sync summary and account-groups partial path
- [ ] Rewrite `_priorbank_item.html.erb` using `DS::Disclosure` — header with institution info, status badge, action buttons
- [ ] Render linked accounts via the upstream account-groups partial instead of custom `_priorbank_account`
- [ ] Add inline sync-summary component (replaces `sync_details` page)
- [ ] Add "link account" prompt for unlinked `PriorbankAccount` records
- [ ] Delete the five view files listed above
- [ ] Remove `sync_details` actions from both controllers; remove `sync_details` routes
- [ ] Update `link.html.erb` to `DS::Dialog` if the upstream modal API changed
- [ ] Manual browser check: connected-accounts settings page renders correctly, disclosure opens/closes, sync stats appear inline
- [ ] **No automated tests** — view-only changes, verified manually per project conventions
- [ ] `bin/rails test` — must pass (no regressions)
- [ ] `bin/rubocop -f github -a`
- [ ] `bundle exec erb_lint ./app/**/*.erb -a`

---

### Phase 5: Final CI checks and PR

- [ ] `bin/rails test` — full suite green
- [ ] `bin/rubocop -f github -a` — no offences
- [ ] `bundle exec erb_lint ./app/**/*.erb -a`
- [ ] `bin/brakeman --no-pager` — no new warnings
- [ ] Open PR from `chore/merge-upstream-v0.7.2` into `main`
- [ ] Move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Log in with a real Priorbank account and trigger a full sync — confirm accounts appear, transactions import, Statement Vault shows the downloaded CSV
- Re-trigger sync on same period — confirm no duplicate error and vault skips gracefully
- Check bank sync UI on the connected-accounts settings page — disclosure card opens/closes, sync stats display inline, link-account prompt appears for unlinked accounts

**Deployment:**
- Ensure `FERRUM_BROWSER_PATH` / Chrome binary is available in production Docker image (unchanged from before)
- New `account_statements` table migration runs on deploy (`bin/rails db:migrate`)
