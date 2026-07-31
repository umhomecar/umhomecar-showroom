# Migration E — close unauthenticated read access to `um_car_sales_events(uuid)`

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date executed:** 2026-07-31
- **Status:** ✅ Executed and verified. All E0–E9 checks passed. No rollback needed.
- **Type:** privilege-only. **The function body was not modified** — proven by
  checksum, see §7.
- **Scope:** `EXECUTE` on ONE function, `public.um_car_sales_events(uuid)`.
  No data, no RLS policies, no other functions, no schema-wide DEFAULT
  PRIVILEGES, no R2, no image columns, no edge functions, no cron.

---

## 1. Confirmed finding

`public.um_car_sales_events(p_car_id uuid)` was `SECURITY DEFINER`, owned by
`postgres` (which has `rolbypassrls = true`), with `EXECUTE` granted to
`PUBLIC`, `anon`, `authenticated` and `service_role`, and **no authorization
guard of any kind** — no `auth.uid()`, no `is_admin()`, no `um_is_admin()`, no
role check.

It reads `public.transactions`. That table has RLS enabled with a single policy
`umhome auth full` (`FOR ALL TO authenticated`), so `anon` is correctly denied
direct access. The `SECURITY DEFINER` + `postgres` owner combination bypassed
that policy entirely.

**This is a confirmed information disclosure, and it is now closed.**

Measured directly, in a rolled-back transaction, immediately before the
migration:

| As `anon` | Result |
|---|---|
| `SELECT count(*) FROM public.transactions` | **0 rows** (RLS working) |
| `SELECT count(*) FROM public.um_car_sales_events('b86b3eec-…'::uuid)` | **37 rows** of event history |

The path was directly exploitable, not theoretical: the publishable key is
embedded in the public `index.html`, and the public showroom view
`public.public_cars` exposes an `id` column, so any visitor could enumerate
every listed car's id and pull its full timeline.

### What was disclosed, and what was not

Disclosed: internal transaction identifiers, and the dates, creation
timestamps, derived status and ordering of every booking / approval / delivery /
cancellation event for any listed car.

**Not disclosed:** `transactions` carries `plate`, `old_plate`, `model`,
`old_model`, `branch`, `bank`, `seller` and `source`, but the function's
`SELECT` list projects none of them. It returns only `transaction_id`,
`event_date`, `event_created_at`, `event_status`, `event_priority`,
`event_side`. No customer, salesperson, bank, branch or licence plate was
exposed. **This was internal business-data disclosure, not a PII leak.**

Full audit: `2026-07-31-audit-um-car-sales-events.md`.

## 2. Caller / dependency analysis

Re-confirmed immediately before executing.

Scanning `pg_proc.prosrc` across the whole database, only two references exist:

| Caller | Security | Owner |
|---|---|---|
| `public.um_sync_one_car_sales_status(uuid)` | `SECURITY DEFINER` | `postgres` |
| `public.um_sync_all_car_sales_statuses()` | `SECURITY DEFINER` | `postgres` |

The complete runtime chains, with every link's owner verified in one query
(all five are `SECURITY DEFINER`, owner `postgres`, `rolbypassrls = true`):

```
trigger trg_um_sync_transaction_car_statuses   (on public.transactions)
  └→ um_sync_transaction_car_statuses()        DEFINER · postgres
      └→ um_sync_one_car_sales_status(uuid)    DEFINER · postgres
          └→ um_car_sales_events(uuid)         DEFINER · postgres

um_admin_sync_all_car_sales_statuses()         DEFINER · postgres   (Migration D)
  └→ um_sync_all_car_sales_statuses()          DEFINER · postgres
      └→ um_sync_one_car_sales_status(uuid)
          └→ um_car_sales_events(uuid)
```

Because every link is `SECURITY DEFINER` owned by `postgres`, `EXECUTE` on
`um_car_sales_events` is checked against the **definer**, never against the end
user. Revoking `anon` / `authenticated` / `service_role` therefore cannot break
the sync chain — and E4/E6 prove it empirically rather than by argument.

**No caller outside the database.** `grep` across `umhomecar-showroom`
(`index.html`, `admin.html`, `showroom-color-addon.js`) and
`umhome-summary-web` (`src/`, `api/`, `cloudflare/`, `supabase/`, covering
`.js .mjs .ts .jsx .sql .json`, excluding `node_modules`) returns no match.
`cron.job` holds only `auto-delete-sold-cars-daily`. None of the three edge
functions reference it.

Exactly **one overload** exists — `um_car_sales_events(uuid)` — so the `REVOKE`
was unambiguous.

## 3. SQL applied (final)

```sql
BEGIN;

REVOKE ALL ON FUNCTION public.um_car_sales_events(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
```

All four roles are named explicitly. This project has `ALTER DEFAULT
PRIVILEGES` (grantor `postgres`, schema `public`, objtype `f`) granting
`EXECUTE` to `anon`, `authenticated` and `service_role` on every new function,
and the `=X/postgres` ACL entry is the `PUBLIC` grant from the same source.
Naming only `PUBLIC, anon` — the mistake that failed Migration D's first
attempt — would have left `authenticated` and `service_role` holding `EXECUTE`.

Per instruction, the schema-wide DEFAULT PRIVILEGES themselves were **not**
changed.

### Why `service_role` was revoked too

It has no caller, and removing the grant takes away nothing it needs:
`service_role` holds `rolbypassrls` and can read `public.transactions`
directly, which is a shorter path to the same data.

## 4. Rollback (not used)

```sql
BEGIN;
GRANT EXECUTE ON FUNCTION public.um_car_sales_events(uuid)
  TO PUBLIC, anon, authenticated, service_role;
COMMIT;
```

**This reopens the confirmed disclosure** — anyone holding the publishable key
regains the ability to read any car's booking history with RLS bypassed. Use
only in an emergency.

## 5. ACL before / after

**Before**
```
=X/postgres | postgres=X/postgres | anon=X/postgres
| authenticated=X/postgres | service_role=X/postgres
```

**After**
```
postgres=X/postgres
```

| Grantee | Before | After | Desired | |
|---|---|---|---|---|
| `PUBLIC` (`=X`) | EXECUTE | — | no EXECUTE | ✅ |
| `anon` | EXECUTE | `false` | no EXECUTE | ✅ |
| `authenticated` | EXECUTE | `false` | no EXECUTE | ✅ |
| `service_role` | EXECUTE | `false` | no EXECUTE | ✅ |
| `postgres` (owner) | EXECUTE | `true` | EXECUTE | ✅ |

Unchanged properties: `SECURITY DEFINER`, owner `postgres`, `STABLE`,
`LANGUAGE sql`, `SET search_path TO 'public'`.

## 6. Test results

Executed 2026-07-31 after the migration. Every DML test wrapped in
`BEGIN … ROLLBACK`; nothing persisted.

Fixtures: admin `bcb8b223-3711-4d87-92c2-8d5d78f7e052`,
sales `4c044d09-7ac0-4923-b47c-d75f3e6007c3`,
car `b86b3eec-94a5-45af-ad18-a910f98e9641`.

| # | Test | Result | Status |
|---|---|---|---|
| E0 | baseline, fingerprint, and `anon` reading the function | 37 event rows returned — the disclosure, captured before closing it | ✅ |
| E1 | `anon` calls the function | `42501 permission denied for function um_car_sales_events` | **PASS** |
| E2 | `authenticated` (sales) calls it | `42501` | **PASS** |
| E2b | `authenticated` (**admin**) calls it | `42501` — intended, no UI path calls it directly | **PASS** |
| E3 | `service_role` calls it | `42501` | **PASS** |
| E4 | internal `um_sync_one_car_sales_status` | `sync_one_ok`, car `sold`, `sales_status_synced = true` | **PASS** |
| E5 | internal `um_sync_all_car_sales_statuses` | `288 / 44 / 15 / 124 / 105` | **PASS** |
| E5b | Migration D wrapper `um_admin_sync_all_car_sales_statuses` | `288 / 44 / 15 / 124 / 105` | **PASS** |
| E6 | transaction trigger sync | `trigger_ok`, no permission error | **PASS** |
| E7 | body / functiondef checksums + ACL | both md5 identical to E0; ACL `postgres=X/postgres` | **PASS** |
| E8 | other functions in the chain untouched | ACLs and body md5 all unchanged | **PASS** |
| E8b | `anon` reads `public_cars` | 244, same as E0 | **PASS** |
| E9 | rerun E0 baseline | all image checksums identical | **PASS** |

### Two tests designed to avoid false confidence

**E4 was run as `service_role`** — a role that had *just* been revoked on
`um_car_sales_events` but can still execute `um_sync_one_car_sales_status`.
Passing proves `EXECUTE` is resolved against the definer, not the caller.

**E6 was run as a `sales` identity, not as `postgres`.** During Migration B the
equivalent trigger test was first run as `postgres` — which still held the
privilege — and proved nothing; it had to be redone. Running it as a role that
genuinely lacks `EXECUTE` on `um_car_sales_events` is what makes the result
meaningful.

**E5b** was added because Migration D had just shipped to production. The Data
Health button reaches `um_car_sales_events` through two nested definer hops, so
without this check Migration E could have silently broken a fix deployed hours
earlier.

## 7. Body and definition checksums

| Checksum | Before | After | |
|---|---|---|---|
| `md5(prosrc)` | `333aaabf6a19b7d20f324b8ebab94e75` | `333aaabf6a19b7d20f324b8ebab94e75` | identical |
| `md5(pg_get_functiondef(oid))` | `e38be4ff97e6dd1d588879ed5e66fb79` | `e38be4ff97e6dd1d588879ed5e66fb79` | identical |

This is the proof that the migration was privilege-only and the function body
was never touched.

Other functions in the chain, verified unchanged (E8):

| Function | ACL after | body md5 |
|---|---|---|
| `um_sync_one_car_sales_status` | `postgres=X \| service_role=X` | `6dfb32ccde73ba91b935310185a59463` |
| `um_sync_all_car_sales_statuses` | `postgres=X \| service_role=X` | `b59d1f522905cb3c314a857c80e73c93` |
| `um_admin_sync_all_car_sales_statuses` | `postgres=X \| authenticated=X` | `57a1fcb562da7f89d5769ec22c1c997c` |
| `um_sync_transaction_car_statuses` | unchanged (see §9) | `76648f0f0e5ea5a0c1312df6cba1355a` |

## 8. cars / car_images / R2 / image URLs unchanged

Captured at 16:40:03 (before) and 16:42:58 (after), Asia/Bangkok:

| Metric | Before | After | |
|---|---|---|---|
| `cars` count | 288 | 288 | ✅ |
| `car_images` count | 5005 | 5005 | ✅ |
| `public_cars` count | 244 | 244 | ✅ |
| `md5(cars.cover_image_url)` | `da4bd4518a61c414196a1ee71ba0accf` | same | ✅ |
| `md5(car_images.image_url + storage_path)` | `e91f79830d83c15acfd063a26f714e7f` | same | ✅ |
| `md5(cars.status)` | `eedb9da524a24d194c5e82a74888af5f` | same | ✅ |

R2 was never contacted; no R2 key was read or written. No edge function or cron
schedule was modified. This migration changed exactly one ACL.

## 9. Outcome

Executed 2026-07-31. **Successful.** The confirmed unauthenticated,
RLS-bypassing read path into transaction history is closed — what returned 37
rows of a car's sales timeline to `anon` now returns `42501` — while the entire
internal sync chain, the transaction trigger, the Data Health admin wrapper and
the public showroom all continue to work unchanged.

## 10. Known gaps / follow-ups

- Applied with `execute_sql`, not `apply_migration`, so **no row was added to
  Supabase migration history** (same as A, B and D).
- `public.um_sync_transaction_car_statuses()` still carries
  `=X | anon=X | authenticated=X | service_role=X`. It is a trigger function
  (`RETURNS trigger`) and cannot be invoked directly from SQL, so it is not an
  attack path — noted for completeness, deliberately left untouched as it falls
  outside this migration's scope.
- The `pg_default_acl` behaviour means **every future function** created in
  `public` is born granted to `anon`, `authenticated` and `service_role`.
  Any new migration must revoke all four explicitly before granting.
- Migration C (Phase 2b — `cars` / `car_images` admin-only writes) is drafted
  but **not executed**.
