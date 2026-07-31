# Migration C (Phase 2b) — `cars` / `car_images` admin-only writes, `car_status_history` append-only

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date executed:** 2026-07-31
- **Status:** ✅ Executed and verified. All C1–C16 passed. No rollback performed.
- **Type:** RLS policies only. No data, no grants, no functions, no schema-wide
  DEFAULT PRIVILEGES.
- **Scope:** `public.cars`, `public.car_images`, `public.car_status_history`.

---

## 1. Vulnerability

All three tables had RLS enabled but carried a single policy:

```
"umhome auth full"   FOR ALL TO authenticated   USING (true)   WITH CHECK (true)
```

Every authenticated user — including `role = 'sales'` — therefore had full
`INSERT` / `UPDATE` / `DELETE` on cars, car images and status history at the
database level.

The `umhome-summary-web` UI blocks all of it: `SALES_BLOCKED` in `src/main.js`
intercepts every `cs-*` write action, the upload input has its own guard, and
drag-reorder and bulk-delete each check `state.role === 'sales'`. But UI gating
is not authorization. A signed-in sales user could bypass every one of those
checks by calling PostgREST directly with their own session token and edit
prices, flip statuses, delete cars, or delete image rows.

`anon` was never able to reach these tables — no `anon` policy existed — and
still cannot.

### Why RLS is sufficient here

The three "atomic" RPCs the frontend calls —
`um_set_car_status_atomic`, `um_delete_car_images_atomic`,
`um_reorder_car_images_atomic` — **do not exist** in this database (verified: no
match in `pg_proc`, any schema). `src/api/cars.js` catches `PGRST202` via
`isMissingRpc()` and falls back to direct table DML. So 100% of frontend car
writes are plain `INSERT`/`UPDATE`/`DELETE` against these tables, fully governed
by RLS. There is no `SECURITY DEFINER` bypass to design around.

### Why `car_status_history` is append-only rather than admin-CRUD

Verified before choosing it:

- The only code reference anywhere is an INSERT —
  `umhome-summary-web/src/api/cars.js:167`, inside `setCarStatus()`'s fallback.
  No `UPDATE` and no `DELETE` against this table exists in either repository.
- No trigger exists on `car_status_history`, and no database function
  references it (`pg_trigger` and `pg_proc.prosrc` both empty).
- Rows are still removed when their car is deleted, through
  `car_status_history_car_id_fkey FOREIGN KEY (car_id) REFERENCES cars(id) ON DELETE CASCADE`.
  A referential-action cascade is performed by the system, not as the invoking
  user, so it is not subject to RLS and needs no DELETE policy — proven by C16.

Net effect: an audit trail that can be appended to and read, but never silently
altered — including by an admin, and including by a compromised admin session.

## 2. C0 baseline

Captured immediately before executing, at **2026-07-31 22:10:51 Asia/Bangkok**:

| Metric | Value |
|---|---|
| `cars` | 288 |
| `car_images` | 5005 |
| `car_status_history` | 2 |
| `public_cars` | 222 |
| `md5(cars.cover_image_url)` | `da4bd4518a61c414196a1ee71ba0accf` |
| `md5(car_images.image_url + storage_path)` | `e91f79830d83c15acfd063a26f714e7f` |
| `md5(cars.status)` | `32b2a44e9045eb50a410317e9bde82a3` |

Policy state confirmed at the same moment: exactly 3 policies, one
`umhome auth full` per table, RLS on, force off. No v16 artifacts present
(`um_car%` policies 0, atomic RPCs 0, `idx_cars_active_created` /
`idx_car_images_cover` 0).

Fixtures re-verified rather than assumed: admin
`bcb8b223-3711-4d87-92c2-8d5d78f7e052`, sales
`4c044d09-7ac0-4923-b47c-d75f3e6007c3`, car
`b86b3eec-94a5-45af-ad18-a910f98e9641` (29 non-deleted transactions).

## 3. SQL applied (final)

Executed as a single transaction.

```sql
BEGIN;

-- ---------------- cars: 4 policies ----------------
DROP POLICY IF EXISTS "umhome auth full" ON public.cars;

CREATE POLICY "cars select (authenticated)"
  ON public.cars FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "cars insert (admin)"
  ON public.cars FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.is_admin()));

CREATE POLICY "cars update (admin)"
  ON public.cars FOR UPDATE TO authenticated
  USING ((SELECT public.is_admin()))
  WITH CHECK ((SELECT public.is_admin()));

CREATE POLICY "cars delete (admin)"
  ON public.cars FOR DELETE TO authenticated
  USING ((SELECT public.is_admin()));

-- ---------------- car_images: 4 policies ----------------
DROP POLICY IF EXISTS "umhome auth full" ON public.car_images;

CREATE POLICY "car_images select (authenticated)"
  ON public.car_images FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "car_images insert (admin)"
  ON public.car_images FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.is_admin()));

CREATE POLICY "car_images update (admin)"
  ON public.car_images FOR UPDATE TO authenticated
  USING ((SELECT public.is_admin()))
  WITH CHECK ((SELECT public.is_admin()));

CREATE POLICY "car_images delete (admin)"
  ON public.car_images FOR DELETE TO authenticated
  USING ((SELECT public.is_admin()));

-- ---------------- car_status_history: 2 policies (APPEND-ONLY) ----------------
DROP POLICY IF EXISTS "umhome auth full" ON public.car_status_history;

CREATE POLICY "car_status_history select (authenticated)"
  ON public.car_status_history FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "car_status_history insert (admin)"
  ON public.car_status_history FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.is_admin()));

-- Deliberately NO update policy and NO delete policy on car_status_history.
-- With RLS enabled and no permissive policy for a command, that command is
-- denied for every role subject to RLS.

COMMIT;
```

Design notes:

- `is_admin()` is wrapped in a scalar subquery so Postgres evaluates it once per
  statement as an InitPlan rather than once per row — this matters on
  `car_images` (5,005 rows).
- `is_admin()` reads `public.profiles`, not `cars`/`car_images`, so there is no
  RLS recursion.
- Table grants were **not** touched. `anon` still holds raw grants but has no
  policy on any of these tables, so RLS denies it — verified by C11.

## 4. Rollback (not used)

```sql
BEGIN;

DROP POLICY IF EXISTS "cars select (authenticated)" ON public.cars;
DROP POLICY IF EXISTS "cars insert (admin)"         ON public.cars;
DROP POLICY IF EXISTS "cars update (admin)"         ON public.cars;
DROP POLICY IF EXISTS "cars delete (admin)"         ON public.cars;
CREATE POLICY "umhome auth full"
  ON public.cars FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "car_images select (authenticated)" ON public.car_images;
DROP POLICY IF EXISTS "car_images insert (admin)"         ON public.car_images;
DROP POLICY IF EXISTS "car_images update (admin)"         ON public.car_images;
DROP POLICY IF EXISTS "car_images delete (admin)"         ON public.car_images;
CREATE POLICY "umhome auth full"
  ON public.car_images FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "car_status_history select (authenticated)" ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history insert (admin)"         ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history update (admin)"         ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history delete (admin)"         ON public.car_status_history;
CREATE POLICY "umhome auth full"
  ON public.car_status_history FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMIT;
```

**This restores full write access for every authenticated user, sales
included, and removes the append-only guarantee.** Emergency use only. The
`update`/`delete` drops on `car_status_history` are harmless no-ops kept in case
an earlier 4-policy variant was ever applied.

## 5. Policy before / after

**Before — 3 policies**

| Table | Policy | Cmd | Roles | USING / WITH CHECK |
|---|---|---|---|---|
| `cars` | `umhome auth full` | ALL | `{authenticated}` | `true` / `true` |
| `car_images` | `umhome auth full` | ALL | `{authenticated}` | `true` / `true` |
| `car_status_history` | `umhome auth full` | ALL | `{authenticated}` | `true` / `true` |

**After — 10 policies**

| Table | Policy | Cmd | Roles | USING | WITH CHECK |
|---|---|---|---|---|---|
| `cars` | `cars select (authenticated)` | SELECT | `{authenticated}` | `true` | — |
| `cars` | `cars insert (admin)` | INSERT | `{authenticated}` | — | `(SELECT is_admin())` |
| `cars` | `cars update (admin)` | UPDATE | `{authenticated}` | `(SELECT is_admin())` | `(SELECT is_admin())` |
| `cars` | `cars delete (admin)` | DELETE | `{authenticated}` | `(SELECT is_admin())` | — |
| `car_images` | `car_images select (authenticated)` | SELECT | `{authenticated}` | `true` | — |
| `car_images` | `car_images insert (admin)` | INSERT | `{authenticated}` | — | `(SELECT is_admin())` |
| `car_images` | `car_images update (admin)` | UPDATE | `{authenticated}` | `(SELECT is_admin())` | `(SELECT is_admin())` |
| `car_images` | `car_images delete (admin)` | DELETE | `{authenticated}` | `(SELECT is_admin())` | — |
| `car_status_history` | `car_status_history select (authenticated)` | SELECT | `{authenticated}` | `true` | — |
| `car_status_history` | `car_status_history insert (admin)` | INSERT | `{authenticated}` | — | `(SELECT is_admin())` |

No `umhome auth full` remains. No policy grants anything to `anon`. All
policies are permissive; RLS on, force off, unchanged.

## 6. Test results — C1 to C16

Every DML test wrapped in `BEGIN … ROLLBACK`; nothing persisted.

| # | Test | Result | Status |
|---|---|---|---|
| C1 | sales SELECT `cars` | 288 — equals C0 | **PASS** |
| C2 | sales SELECT `car_images` | 5005 — equals C0 | **PASS** |
| C2b | sales SELECT `car_status_history` | 2 — equals C0 | **PASS** |
| C3 | sales INSERT `cars` | `42501 new row violates row-level security policy for table "cars"` | **PASS** |
| C4 | sales UPDATE `cars` (status, then price) | 0 rows, 0 rows | **PASS** |
| C5 | sales DELETE `cars` | 0 rows | **PASS** |
| C6 | sales INSERT / UPDATE / DELETE `car_images` | `42501` / 0 / 0 | **PASS** |
| C6b | sales INSERT / UPDATE / DELETE `car_status_history` | `42501` / 0 / 0 | **PASS** |
| C7 | sales calls `um_fix_missing_covers()` / `um_admin_sync_all_car_sales_statuses()` | `P0001 admin only` / `42501 permission denied: admin only` | **PASS** |
| C8 | admin INSERT / UPDATE / DELETE `cars` | insert 1, update applied 1, remaining 0 | **PASS** |
| C9 | admin INSERT / UPDATE / DELETE `car_images` | insert 1, update applied 1, remaining 0 | **PASS** |
| C9b | admin INSERT `car_status_history` | 1 | **PASS** |
| C9c | **admin UPDATE `car_status_history`** | update applied 0 — denied | **PASS** |
| C9d | **admin DELETE `car_status_history`** | 3 rows still present — nothing deleted | **PASS** |
| C9e | admin `setCarStatus()` fallback: UPDATE cars + INSERT history in one transaction | 1 / 1 | **PASS** |
| C16 | hard delete a car holding history | history_before 1 → car removed → history_after 0 (cascade) | **PASS** |
| C10 | anon SELECT `public_cars` | 222 — equals C0 | **PASS** |
| C11 | anon SELECT `cars` / `car_images` / `car_status_history` | 0 / 0 / 0 | **PASS** |
| C12 | transaction trigger sync, run as **sales** | `c12_trigger_ok`, car `sold`, `sales_status_synced = true` | **PASS** |
| C13 | service_role SELECT + UPDATE `cars` | 288, update ok | **PASS** |
| C14 | `um_fix_missing_covers()` as admin | `{"fixed_count": 0}`, no error | **PASS** |
| C15 | Migration D wrapper `um_admin_sync_all_car_sales_statuses()` | `287 / 65 / 4 / 118 / 100` | **PASS** |

C12 was deliberately run as a **sales** identity, not as `postgres`. Sales can
write `transactions` (that table's policy is unchanged) but can no longer write
`cars`; the AFTER trigger then reaches `cars` through
`um_sync_transaction_car_statuses()` → `um_sync_one_car_sales_status()`, both
`SECURITY DEFINER` owned by `postgres`. Running it as `postgres` would have
proven nothing — that mistake was made and corrected during Migration B.

C15 returning `total_cars = 287` against a table of 288 is not a discrepancy:
`um_sync_all_car_sales_statuses()` counts only `is_archived = false`.

### C8 and C9 — retested, then passed

Both initially produced results that looked like failures. Neither was a policy
problem, and **the migration was not modified** — only the test method was
corrected.

**C8.** The first attempt put `INSERT`, `UPDATE` and `DELETE` in three CTEs of
one statement and reported `update 0, delete 0`. That is standard Postgres CTE
semantics: all CTEs of a statement see the same snapshot, so the `UPDATE` and
`DELETE` branches could not see the row the `INSERT` branch had just created.
Rerun with the id captured into a temp table and each command issued as its own
statement, the result was insert 1, update applied 1, remaining after delete 0.

**C9.** The first attempt failed with
`23502 null value in column "storage_path" ... violates not-null constraint` —
the test simply omitted a required column. Rerun supplying a placeholder
`storage_path` on a scratch car created inside the same rolled-back
transaction: insert 1, update applied 1, remaining 0. **No real
`car_images` row, `image_url` or `storage_path` was touched** — confirmed by the
unchanged checksums in §7.

## 7. C0 / C-LAST — checksums

C-LAST captured **2026-07-31 22:17:10 Asia/Bangkok**.

| Metric | C0 (22:10:51) | C-LAST (22:17:10) | Gate | Result |
|---|---|---|---|---|
| `md5(cars.cover_image_url)` | `da4bd4518a61c414196a1ee71ba0accf` | `da4bd4518a61c414196a1ee71ba0accf` | **required** | ✅ identical |
| `md5(car_images.image_url + storage_path)` | `e91f79830d83c15acfd063a26f714e7f` | `e91f79830d83c15acfd063a26f714e7f` | **required** | ✅ identical |
| `cars` count | 288 | 288 | informational | unchanged |
| `car_images` count | 5005 | 5005 | informational | unchanged |
| `car_status_history` count | 2 | 2 | informational | unchanged |
| `public_cars` count | 222 | 222 | informational | unchanged |
| `md5(cars.status)` | `32b2a44e9045eb50a410317e9bde82a3` | `32b2a44e9045eb50a410317e9bde82a3` | informational | unchanged |

**Both mandatory gates passed.** `cover_image_url` and the combined
`image_url + storage_path` fingerprint are byte-identical, so no image URL or
storage path moved.

### What changed during testing

**Nothing.** Even the informational metrics — which were explicitly allowed to
drift because production is in use — are identical across both captures. Every
test ran inside `BEGIN … ROLLBACK`, and no real user activity landed in the
22:10–22:17 window.

For context, earlier in the same evening `public_cars` did move from 244 to 222
and `md5(cars.status)` changed, as staff updated car statuses. That is exactly
why those metrics are informational rather than gates, and why the test plan
carries no hardcoded baseline values.

## 8. Not touched

| Item | Evidence |
|---|---|
| **R2** | Never contacted. No R2 key read or written. |
| **`cover_image_url`** | Checksum identical across C0/C-LAST (§7). |
| **`image_url` / `storage_path`** | Combined checksum identical across C0/C-LAST (§7). |
| **Edge Functions** | Not modified. `auto-delete-sold-cars`, `admin-create-user`, `admin-reset-password` untouched. |
| **cron** | `auto-delete-sold-cars-daily` untouched. |
| **v16** | `supabase/v16_car_stock_stability.sql` not executed. Confirmed 0 `um_car%` policies, 0 atomic RPCs, 0 v16 indexes before and after. It is marked SUPERSEDED on `main` (PR #27, merge commit `484990a`). |
| **Schema-wide DEFAULT PRIVILEGES** | Not altered. |
| **Table grants** | Not altered on any of the three tables. |
| **`transactions` policy** | Unchanged — required by C12. |

## 9. Outcome

Executed 2026-07-31. **Successful.** A `sales` user can still read cars, images
and status history — which `listCars()` and `getCar()` require — but can no
longer insert, update or delete any of them at the database level, closing the
gap between the UI's `SALES_BLOCKED` list and what PostgREST would actually
accept. Admins retain full CRUD on cars and images. `car_status_history` is now
append-only for everyone, so the audit trail cannot be rewritten or erased even
with an admin session. The public showroom, the transaction sync trigger, the
`service_role` maintenance paths, `um_fix_missing_covers()` and the Migration D
Data Health wrapper all continue to work, each verified by an executed test.

This completes the security work: **A, B, C, D and E are all live.**

| Finding | Closed by |
|---|---|
| `anon` writes `public.cars` via unguarded `SECURITY DEFINER` RPC | B |
| `sales` escalates itself to `admin` via `profiles` | A |
| Sole admin can demote itself into a zero-admin lockout | A |
| `anon` reads any car's transaction history with RLS bypassed | E |
| `sales` writes `cars` / `car_images` / `car_status_history` directly | **C** |

## 10. Known gaps / follow-ups

- Applied with `execute_sql`, not `apply_migration`, so **no row was added to
  Supabase migration history** — same as A, B, D and E. Needs backfilling if
  this project tracks schema history.
- `anon` still holds raw `INSERT`/`UPDATE`/`DELETE` **grants** on all three
  tables. RLS denies it (no `anon` policy exists, verified by C11), so this is
  unused surface rather than a live hole. Revoking the grants was drafted as an
  optional block and deliberately left out, since it was not part of the
  approved desired state.
- The three atomic RPCs remain absent, so status changes and image reordering
  are still non-atomic multi-statement sequences from the client. The
  definitions in `v16_car_stock_stability.sql` are the obvious starting point if
  that is ever addressed — extracted individually, never by running that file.
- `public.um_sync_transaction_car_statuses()` still carries a wide ACL
  (`=X | anon=X | authenticated=X | service_role=X`). It is a trigger function
  (`RETURNS trigger`) and cannot be invoked directly from SQL, so it is not an
  attack path. Noted for completeness.
