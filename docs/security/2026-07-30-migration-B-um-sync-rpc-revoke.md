# Migration B — Revoke anon/PUBLIC exposure of `um_sync_*` RPCs

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date executed:** 2026-07-30
- **Status:** ✅ Executed and verified. All tests passed. No rollback needed.
- **Scope:** EXECUTE privileges only. No function bodies, no data, no edge
  functions, no cron, no RLS policies, no R2, no image columns.

---

## 1. Vulnerability

Two `SECURITY DEFINER` functions owned by `postgres` were granted `EXECUTE` to
`PUBLIC`, `anon`, and `authenticated`:

- `public.um_sync_all_car_sales_statuses()`
- `public.um_sync_one_car_sales_status(uuid)`

Neither body contained `auth.uid()`, `is_admin()`, `um_is_admin()`, or any
other guard.

The exploit chain was confirmed statically, all four links verified:

1. `anon` held `EXECUTE` — `has_function_privilege('anon', ..., 'EXECUTE') = true`
2. Both are `SECURITY DEFINER` owned by `postgres`, which has `rolbypassrls = true`
3. `public.cars` has RLS enabled but `relforcerowsecurity = false`, so the
   owner bypasses RLS completely
4. The `anon` key is embedded in the public `index.html`, and schema `public`
   is exposed through PostgREST

Net effect: any internet caller could `POST /rest/v1/rpc/um_sync_all_car_sales_statuses`
with the publicly readable anon key and write `public.cars`
(`status`, `sold_at`, `sales_status_synced`, `sales_status_transaction_id`,
`sales_status_updated_at`) with RLS bypassed.

Damage was bounded — values are recomputed from `public.transactions`, not
attacker-chosen — but it allowed forced mass resync (overwriting manually set
statuses, and reverting `sales_status_synced` rows to `available`) and
unauthenticated repeated invocation of a full-table loop (DoS).

## 2. Why privileges alone were sufficient

The only legitimate caller is the trigger function
`public.um_sync_transaction_car_statuses()` (on `public.transactions`, via
`trg_um_sync_transaction_car_statuses`), which is itself `SECURITY DEFINER`
owned by `postgres`. Postgres checks `EXECUTE` against the **definer**, not the
invoking end user, so revoking `anon`/`authenticated` does not affect the
trigger path. No function body was changed.

### Caller analysis (all paths checked)

| Path | Calls `um_sync_*`? | Needs end-user EXECUTE? |
|---|---|---|
| `um_sync_transaction_car_statuses()` trigger fn | yes | no — SECURITY DEFINER, owner `postgres` |
| `um_sync_all_car_sales_statuses()` | yes (loops `um_sync_one`) | no — SECURITY DEFINER |
| `cron.job` (1 job: `auto-delete-sold-cars-daily`) | no | — |
| Edge fn `auto-delete-sold-cars` | no | — |
| Edge fn `admin-create-user` | no | — |
| Edge fn `admin-reset-password` | no | — |
| Front end (`index.html`, `admin.html`, `showroom-color-addon.js`) | no | — |

The front end only calls `is_showroom_admin`, `get_showroom_favorite_counts`,
`bump_car_view`, `sync_showroom_favorites`, `set_showroom_favorite`.

## 3. SQL executed

Run as a single transaction via `execute_sql`.

```sql
BEGIN;

REVOKE ALL ON FUNCTION public.um_sync_all_car_sales_statuses()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.um_sync_all_car_sales_statuses()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  TO service_role;

COMMIT;
```

`service_role` already held `EXECUTE`; the `GRANT`s are no-ops against the
prior state and exist so the final ACL is declared by this migration and the
file is idempotent.

## 4. Privileges before / after

Both functions had identical ACLs.

**Before**
```
=X/postgres | postgres=X/postgres | anon=X/postgres
| authenticated=X/postgres | service_role=X/postgres
```

**After**
```
postgres=X/postgres | service_role=X/postgres
```

| Grantee | Before | After |
|---|---|---|
| `PUBLIC` | EXECUTE | **revoked** |
| `anon` | EXECUTE | **revoked** |
| `authenticated` | EXECUTE | **revoked** |
| `service_role` | EXECUTE | EXECUTE (retained, explicit) |
| `postgres` (owner) | EXECUTE | EXECUTE (retained) |

`authenticated` was revoked rather than retained because no client workflow
invokes either function — verified by grep across the whole repo. This means an
**admin** cannot call them either, which is intentional: no admin UI path uses
them. If an admin-triggered resync is ever wanted, the correct fix is a new
guarded wrapper RPC (`is_admin()` check, granted to `authenticated`), not
re-granting these.

## 5. Test results

All executed 2026-07-30 immediately after the migration. Every DML test was
wrapped in `BEGIN … ROLLBACK`.

| # | Test | Result | Status |
|---|---|---|---|
| T1 | `anon` → `um_sync_all_car_sales_statuses()` | `ERROR 42501: permission denied for function um_sync_all_car_sales_statuses` | PASS |
| T2 | `anon` → `um_sync_one_car_sales_status(uuid)` | `ERROR 42501: permission denied for function um_sync_one_car_sales_status` | PASS |
| T3 | `authenticated` → both functions | `ERROR 42501` on both | PASS |
| T4 | `service_role` → `um_sync_all` | `total_cars=286, sold=43, approved=11, booked=123, available=109` | PASS |
| T5 | trigger sync from `transactions` | no permission error; trigger fired through the definer chain | PASS |
| T6 | `anon` → `SELECT public_cars` | 243 rows | PASS |

### Note on T5 methodology

The first T5 run was executed as `postgres`, which still holds `EXECUTE` — that
did **not** exercise the revoked path and was not valid evidence. It was re-run
as `authenticated` (the role just revoked) with real JWT claims. The
`UPDATE public.transactions` succeeded, the AFTER trigger fired
`um_sync_transaction_car_statuses()`, which called
`um_sync_one_car_sales_status()`, with no permission error. This is the
conclusive proof that the `SECURITY DEFINER` chain is unaffected by the revoke.

### Data integrity — before vs after

Identical across the migration, confirming nothing touched cars, images, or R2:

| Metric | Before | After |
|---|---|---|
| `cars` count | 286 | 286 |
| `md5(cars.cover_image_url)` | `36be202656fcadc87dcadd24ef246466` | same |
| `car_images` count | 4966 | 4966 |
| `md5(car_images.image_url + storage_path)` | `8b946f290c230583865abb5139338b90` | same |
| `md5(cars.status)` | `06cb20cc1fb944ad147189b2a6cb3952` | same |
| `md5(prosrc)` `um_sync_all` | `b59d1f522905cb3c314a857c80e73c93` | same |
| `md5(prosrc)` `um_sync_one` | `6dfb32ccde73ba91b935310185a59463` | same |

### No collateral damage

RPCs the front end actually uses were re-checked after the migration and all
retain `anon` EXECUTE: `bump_car_view`, `get_showroom_favorite_counts`,
`set_showroom_favorite`, `sync_showroom_favorites`, `is_showroom_admin`.
`um_fix_missing_covers` remains `anon=false / authenticated=true` as before.

## 6. Rollback (not used)

Restores the exact pre-migration ACL. **This reopens the vulnerability** — for
emergency use only.

```sql
BEGIN;
GRANT EXECUTE ON FUNCTION public.um_sync_all_car_sales_statuses()
  TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  TO PUBLIC, anon, authenticated;
COMMIT;
```

## 7. Known gaps / follow-ups

- Executed with `execute_sql`, not `apply_migration`, so **no row was added to
  Supabase migration history**. If this project tracks schema history, the
  change needs to be backfilled there.
- `public.um_car_sales_events(uuid)` is still `SECURITY DEFINER` with `anon`
  EXECUTE. It is `STABLE` and writes nothing, but it lets `anon` read the
  transaction history of any car with RLS bypassed — a data-disclosure issue
  outside this migration's scope, not yet triaged.
- Migration A (`profiles` role privilege escalation) is drafted but **not
  executed**.
