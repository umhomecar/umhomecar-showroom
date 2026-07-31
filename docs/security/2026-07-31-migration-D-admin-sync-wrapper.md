# Migration D — admin-only wrapper for the Data Health sync

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date executed:** 2026-07-31
- **Status:** ✅ Executed, verified, and confirmed working in production. All tests passed.
- **Scope:** creates ONE new function. The internal `um_sync_all_car_sales_statuses()`
  is untouched — neither its body nor its ACL. No data, no RLS policies, no R2,
  no image columns, no edge functions, no cron.

---

## 1. Regression being fixed

Migration B revoked `EXECUTE` on `public.um_sync_all_car_sales_statuses()` from
`PUBLIC`, `anon` and `authenticated`, leaving the ACL:

```
postgres=X/postgres | service_role=X/postgres
```

But `umhome-summary-web` still called that RPC from the browser as
`authenticated`:

```
src/features/dataHealth.js:280   syncHealthStatuses()
  await supabase.rpc('um_sync_all_car_sales_statuses')
```

reached through the Data Health action `health-sync-status`. An **admin**
clicking that button received `42501 permission denied for function`.

Sales users were never affected — `health-sync-status` is in `SALES_BLOCKED`
and the `health` tab is not in `SALES_TABS`.

### Why this was missed in the Migration B audit

The Migration B caller analysis concluded "no client workflow calls these
RPCs". That conclusion was correct **for the only repository accessible at the
time** (`umhomecar-showroom`). `umhome-summary-web`, which does call it, was not
in the session's GitHub scope until later. The scope of that conclusion should
have been stated explicitly rather than phrased as a global finding.

### Why a wrapper instead of re-granting

Re-granting `authenticated` on the internal function would restore an
unguarded, RLS-bypassing, `public.cars`-writing entry point — exactly the
vulnerability Migration B closed. The wrapper supplies the missing
authorization check instead, and the internal function stays closed.

### How the privilege chain works

The wrapper is `SECURITY DEFINER` owned by `postgres`. Inside it, the call to
`um_sync_all_car_sales_statuses()` has its `EXECUTE` checked against the
**definer** (`postgres`), not the caller — so the inner function does not need
to be granted to `authenticated` for this to work.

## 2. Return signature — verified, not assumed

Queried read-only before drafting:

```
pg_get_function_result(oid) =
  TABLE(total_cars integer, sold integer, approved integer,
        booked integer, available integer)
proretset = true, prorettype = record, pronargs = 0, language = plpgsql
```

Per column, from `unnest(proallargtypes, proargnames, proargmodes)`:

| ord | name | type | mode |
|---|---|---|---|
| 1 | `total_cars` | integer | `t` |
| 2 | `sold` | integer | `t` |
| 3 | `approved` | integer | `t` |
| 4 | `booked` | integer | `t` |
| 5 | `available` | integer | `t` |

The wrapper mirrors this exactly. If the internal function's signature ever
changes, the wrapper must change in lockstep or `return query select *` fails
with a structure mismatch. Test D6 asserts the two stay identical.

## 3. SQL applied (final)

```sql
BEGIN;

CREATE OR REPLACE FUNCTION public.um_admin_sync_all_car_sales_statuses()
RETURNS TABLE(total_cars integer, sold integer, approved integer, booked integer, available integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- Authorization gate. is_admin() is STABLE SECURITY DEFINER and checks
  -- profiles.role = 'admin' for auth.uid(). For anon, auth.uid() is NULL, so
  -- this is false and the call is rejected.
  if not public.is_admin() then
    raise exception
      'permission denied: admin only'
      using errcode = '42501';
  end if;

  return query select * from public.um_sync_all_car_sales_statuses();
end;
$function$;

COMMENT ON FUNCTION public.um_admin_sync_all_car_sales_statuses() IS
  'Admin-only wrapper around um_sync_all_car_sales_statuses(). Exists so the Data Health "sync statuses" button works for admins without re-granting authenticated EXECUTE on the unguarded internal function (see Migration B).';

-- Strip every inherited grant before granting back only what is wanted.
REVOKE ALL ON FUNCTION public.um_admin_sync_all_car_sales_statuses()
  FROM PUBLIC, anon, authenticated, service_role;

-- authenticated may CALL it; non-admins are rejected inside by is_admin().
-- service_role is deliberately NOT granted.
GRANT EXECUTE ON FUNCTION public.um_admin_sync_all_car_sales_statuses()
  TO authenticated;

COMMIT;
```

### `REVOKE ... FROM service_role` is mandatory here — this cost a failed test

The first version of this migration revoked only `PUBLIC, anon`, on the
assumption that "not granting" a role means it has no privilege. **That is
false in this project.** `pg_default_acl` carries, for grantor `postgres`,
schema `public`, objtype `f`:

```
postgres=X/postgres | anon=X/postgres | authenticated=X/postgres | service_role=X/postgres
```

Every newly created function in `public` is therefore **born** with `EXECUTE`
already granted to `anon`, `authenticated` and `service_role`. The first run
left `service_role` holding `EXECUTE` and failed the ACL assertion (test D5).
It was corrected with a follow-up
`REVOKE ALL ... FROM service_role`, and the SQL above now declares the full
revoke so the file is idempotent and self-describing.

**Treat this as the standard pattern for every new function in this project:**
`REVOKE` from all four, then `GRANT` only the intended roles.

### Why `service_role` is not granted on the wrapper

Two independent reasons:

1. `service_role` already holds `EXECUTE` on the internal function and calls it
   directly, so the wrapper would be a redundant second path.
2. `is_admin()` resolves through `auth.uid()`, which is `NULL` for a
   `service_role` request. Even if granted, the wrapper's own guard would
   reject it. Test D4c confirms this.

## 4. Rollback (not used)

Safe — drops only the new wrapper, leaving the internal function's ACL at
`postgres=X/postgres | service_role=X/postgres`.

```sql
BEGIN;
DROP FUNCTION IF EXISTS public.um_admin_sync_all_car_sales_statuses();
COMMIT;
```

**Consequence:** the Data Health "sync statuses" button breaks again for admins
(`42501`). Roll back the frontend change alongside it, or leave the frontend
pointing at the wrapper — it will then fail with "function does not exist"
instead.

## 5. ACL before / after

**Before**

| Function | ACL | anon | authenticated | service_role |
|---|---|---|---|---|
| `um_sync_all_car_sales_statuses` | `postgres=X \| service_role=X` | false | false | true |
| `um_admin_sync_all_car_sales_statuses` | *(did not exist)* | — | — | — |

**After**

| Function | ACL | PUBLIC | anon | authenticated | service_role | postgres |
|---|---|---|---|---|---|---|
| `um_admin_sync_all_car_sales_statuses` | `postgres=X \| authenticated=X` | — | false | **true** | false | owner |
| `um_sync_all_car_sales_statuses` | `postgres=X \| service_role=X` | — | false | **false** | true | owner |

The internal function's body checksum is `b59d1f522905cb3c314a857c80e73c93`
before and after — proof it was never modified.

Wrapper properties: `SECURITY DEFINER`, owner `postgres`,
`search_path = public, pg_temp` (`pg_temp` last, so a caller cannot shadow an
object with a temp table).

## 6. Test results

Run 2026-07-31 after the ACL correction. Every DML test wrapped in
`BEGIN … ROLLBACK`.

Fixtures: admin `bcb8b223-3711-4d87-92c2-8d5d78f7e052`,
sales `4c044d09-7ac0-4923-b47c-d75f3e6007c3`.

| # | Test | Result | Status |
|---|---|---|---|
| D1 | admin → wrapper | 1 row: `288 / 44 / 15 / 124 / 105` | **PASS** |
| D2 | sales → wrapper | `42501 permission denied: admin only` (line 4) | **PASS** |
| D3 | anon → wrapper | `42501 permission denied for function` | **PASS** |
| D4 | authenticated → internal | `42501 permission denied for function` | **PASS** |
| D4b | service_role → internal | 1 row: `288 / 44 / 15 / 124 / 105` | **PASS** |
| D4c | service_role → wrapper | `42501 permission denied for function` | **PASS** |
| D5 | ACL matches desired state | all 10 cells match §5 | **PASS** |
| D6 | wrapper/internal return signature identical | both `TABLE(total_cars integer, sold integer, approved integer, booked integer, available integer)` | **PASS** |

D4c is worth noting: **before** the `service_role` revoke it failed with
`admin only` (it passed the `EXECUTE` check and died at the guard); **after**
the revoke it fails with `permission denied for function`. The change in error
class is the evidence that the revoke took effect.

## 7. Frontend change

Repo `umhomecar/umhome-summary-web`, one line in `src/features/dataHealth.js`:

```diff
 export async function syncHealthStatuses() {
-  const { error } = await supabase.rpc('um_sync_all_car_sales_statuses');
+  const { error } = await supabase.rpc('um_admin_sync_all_car_sales_statuses');
   if (error) throw error;
   toast('ซิงก์สถานะรถแล้ว');
   await ensureHealthLoaded(true);
```

`um_fix_missing_covers()` on the same screen is deliberately untouched — it
already carries its own `um_is_admin()` guard and keeps its `authenticated`
grant.

| | |
|---|---|
| Branch | `claude/data-health-admin-sync-wrapper` |
| Commit | `671ef51bd93949328ec414ee88a712b56d0eb230` |
| PR | [#26](https://github.com/umhomecar/umhome-summary-web/pull/26) |
| Diff | 1 file, +1 −1 |
| CI | Vercel Preview ✅ · Cloudflare Workers Build ✅ |
| Merged | 2026-07-31T09:13:15Z by `umhomecar` |
| Merge commit | `bc208df117985456d2c2efc65e83f13ede20700c` |

Build and tests before merge: `vite build` succeeded (101 modules); all six
suites passed — `test:layout` 4/4, `test:image-compression` 4/4,
`test:image-groups` 4/4, `test:r2-worker` 7/7, `test:clipboard` 4/4,
`test:casemyp` 4/4 (**27/27**).

## 8. Production verification

**PASS** — confirmed by the user on 2026-07-31.

The Data Health "ซิงก์สถานะ" button was exercised on production while signed in
as an admin. The sync completed successfully with no `42501` error, closing the
regression end to end (database → frontend → deployed production).

## 9. Outcome

Executed 2026-07-31. **Successful.** Admins can run the Data Health status sync
again, while `um_sync_all_car_sales_statuses()` remains unreachable from the
browser for `anon` and `authenticated`. Non-admin authenticated users are
rejected by the wrapper's `is_admin()` guard, and `service_role` keeps its
existing direct path to the internal function.

## 10. Known gaps / follow-ups

- Applied with `execute_sql`, not `apply_migration`, so **no row was added to
  Supabase migration history**. Same as Migrations A, B and C — needs
  backfilling if this project tracks schema history.
- The `pg_default_acl` behaviour documented in §3 affects **every future
  function** created in `public`. Any later migration that adds a function and
  forgets the full `REVOKE` will silently leak `EXECUTE` to `anon`,
  `authenticated` and `service_role`.
- `public.um_car_sales_events(uuid)` remains `SECURITY DEFINER` with `anon`
  EXECUTE and no guard. It is `STABLE` and writes nothing, but it lets anyone
  holding the publishable key read any car's booking/approval/delivery timeline
  with RLS bypassed. Audited separately on 2026-07-31 — see
  `2026-07-31-audit-um-car-sales-events.md`. Not yet remediated.
- Migration C (Phase 2b — `cars` / `car_images` admin-only writes) is drafted
  but **not executed**.
