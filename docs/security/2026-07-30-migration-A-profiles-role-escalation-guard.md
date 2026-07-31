# Migration A — `profiles` role privilege escalation guard

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date executed:** 2026-07-30
- **Status:** ✅ Executed successfully and verified. All executable tests passed.
  One test (T8j) was not directly testable — see §6. No rollback performed.
- **Scope:** `public.profiles` only — one trigger function, one trigger, one RLS
  policy, one grant revoke. No changes to `cars`, `car_images`, R2, image URL
  columns, edge functions, or cron.

---

## 1. Vulnerability

Confirmed by direct inspection of the live database (not inherited from a prior
report).

The RLS policy `profiles update (admin or self)` (FOR UPDATE, role
`authenticated`) had:

```
USING      : (is_admin() OR (id = auth.uid()))
WITH CHECK : (is_admin() OR (id = auth.uid()))
```

There was no column restriction, and `authenticated` held table-level `UPDATE`
on **every** column including `role`. Any `sales` user could therefore run:

```sql
UPDATE public.profiles SET role = 'admin' WHERE id = auth.uid();
```

The INSERT policy `profiles insert (admin)` had the same gap —
`WITH CHECK (is_admin() OR (id = auth.uid()))` — permitting a self-insert with
`role = 'admin'`.

`anon` also held raw `INSERT`/`UPDATE` grants on `profiles`. RLS blocked it in
practice (no policy grants `anon` any write), but the grant was unnecessary
attack surface.

## 2. Why a trigger rather than a column-level REVOKE

Admins authenticate through PostgREST as the **same** `authenticated` role as
sales users. `REVOKE UPDATE(role) ON profiles FROM authenticated` would block
admins too, breaking legitimate role management. A trigger can distinguish
admin from non-admin per row; a column grant cannot. Privilege changes alone
were therefore **not** sufficient for this migration (unlike Migration B).

### Paths that had to keep working

| Path | Mechanism | Why it must not break |
|---|---|---|
| `public.handle_new_user()` | SECURITY DEFINER, owner `postgres`; fired by `on_auth_user_created` on `auth.users` | Every signup inserts `profiles` with `role` from `raw_app_meta_data` |
| Edge fn `admin-create-user` | upserts `profiles.role` using `service_role` | Admin user creation |
| Admin role management | `authenticated` + `is_admin()` | Normal operation |
| Sales profile edits | `authenticated`, self row | Normal operation |

## 3. SQL applied

Executed as a single transaction via `execute_sql` on 2026-07-30.

```sql
BEGIN;

CREATE OR REPLACE FUNCTION public.um_guard_profile_role()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- Fail-closed role handling.
  --
  -- (i) Explicitly trusted execution roles bypass the guard. Closed allowlist:
  --       postgres     - owner of handle_new_user() and every SECURITY DEFINER
  --                      function; also the role cron and migrations run as
  --       service_role - the admin-create-user edge function, and the
  --                      documented recovery path (see T8i)
  if current_user in ('postgres', 'service_role') then
    return new;
  end if;

  -- (ii) anon / authenticated fall through to the role rules below.
  -- (iii) Anything else is rejected rather than silently exempted, so a DB role
  --       added in the future cannot bypass this guard by default.
  if current_user not in ('anon', 'authenticated') then
    raise exception
      'permission denied: unexpected execution role'
      using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' then
    if new.role is distinct from old.role then

      -- (a) escalation guard: a non-admin may never change any role
      if not public.is_admin() then
        raise exception
          'permission denied: only an admin can change profiles.role'
          using errcode = '42501';
      end if;

      -- (b) last-admin / self-demotion guard: an admin may change anyone
      --     else's role, but may not strip admin from their OWN account.
      if old.id = auth.uid()
         and old.role = 'admin'
         and new.role is distinct from 'admin' then
        raise exception
          'permission denied: an admin cannot remove admin from their own account; promote another admin first, or use service_role for recovery'
          using errcode = '42501';
      end if;

    end if;
  elsif tg_op = 'INSERT' then
    -- A non-admin may only self-provision at the default privilege level.
    if coalesce(new.role, 'sales') <> 'sales' and not public.is_admin() then
      raise exception
        'permission denied: only an admin can create a profile with role %',
        new.role
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$function$;

COMMENT ON FUNCTION public.um_guard_profile_role() IS
  'Blocks profiles.role escalation by non-admin PostgREST callers (anon/authenticated), and blocks an admin from removing admin from their own account (last-admin lockout guard). Fail-closed: only postgres and service_role bypass, so handle_new_user() and the admin-create-user edge function keep working and service_role remains a recovery path.';

-- Name sorts before trg_profiles_updated, so the guard runs first.
DROP TRIGGER IF EXISTS trg_profiles_guard_role ON public.profiles;
CREATE TRIGGER trg_profiles_guard_role
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.um_guard_profile_role();

-- Compares NEW.role to a literal; does not read profiles, so no RLS recursion.
DROP POLICY IF EXISTS "profiles insert (admin)" ON public.profiles;
CREATE POLICY "profiles insert (admin)"
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (id = auth.uid() AND role = 'sales')
  );

-- Table-scoped only; does NOT alter schema-wide DEFAULT PRIVILEGES.
REVOKE INSERT, UPDATE ON TABLE public.profiles FROM anon;

COMMIT;
```

The UPDATE policy `profiles update (admin or self)` was deliberately left
unchanged — sales users keep editing `username`, `display_name` and
`avatar_url` on their own row exactly as before; only `role` is constrained,
and that is enforced by the trigger.

### Fail-closed allowlist decision

Trusted roles were fixed at `postgres` and `service_role` only. `supabase_admin`
and `dashboard_user` were explicitly considered and **excluded**, on the basis
that the Supabase Dashboard/SQL Editor runs as `postgres`, `handle_new_user()`
is SECURITY DEFINER owned by `postgres`, `admin-create-user` uses
`service_role`, and there is no evidence either role needs to write
`profiles.role`.

Verified not affected: `supabase_auth_admin` (GoTrue) inserts into `auth.users`,
and the `profiles` insert happens inside `handle_new_user()`, where
`current_user` is `postgres`.

## 4. Rollback SQL (NOT executed)

Restores the exact pre-migration state. **This reopens the confirmed
privilege-escalation hole** — emergency use only.

```sql
BEGIN;

-- 1) Remove the guard
DROP TRIGGER IF EXISTS trg_profiles_guard_role ON public.profiles;
DROP FUNCTION IF EXISTS public.um_guard_profile_role();

-- 2) Restore the original INSERT policy verbatim
DROP POLICY IF EXISTS "profiles insert (admin)" ON public.profiles;
CREATE POLICY "profiles insert (admin)"
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (id = auth.uid())
  );

-- 3) Restore anon's write grants on profiles
GRANT INSERT, UPDATE ON TABLE public.profiles TO anon;

COMMIT;
```

## 5. State before / after

### RLS policies on `public.profiles`

| Policy | Cmd | Before | After |
|---|---|---|---|
| `profiles insert (admin)` | INSERT | `WITH CHECK (is_admin() OR (id = auth.uid()))` | `WITH CHECK (is_admin() OR ((id = auth.uid()) AND (role = 'sales'::text)))` |
| `profiles read (authenticated)` | SELECT | `USING true` | unchanged |
| `profiles update (admin or self)` | UPDATE | `USING/WITH CHECK (is_admin() OR (id = auth.uid()))` | unchanged |

### Triggers on `public.profiles`

| Trigger | Before | After |
|---|---|---|
| `trg_profiles_guard_role` | *(did not exist)* | `BEFORE INSERT OR UPDATE … EXECUTE FUNCTION um_guard_profile_role()`, `tgenabled = O` |
| `trg_profiles_updated` | `BEFORE UPDATE … touch_profiles_updated_at()` | unchanged, `tgenabled = O` |

`trg_profiles_guard_role` sorts alphabetically before `trg_profiles_updated`, so
the guard evaluates first.

### Function

`public.um_guard_profile_role()` did not exist before (`guard_fn_exists = 0`);
created by this migration.

### Table grants on `public.profiles`

| Grantee | Before | After |
|---|---|---|
| `anon` | `DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE` | `DELETE,REFERENCES,SELECT,TRIGGER,TRUNCATE` |
| `authenticated` | `DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE` | unchanged |
| `postgres` | `DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE` | unchanged |
| `service_role` | `DELETE,INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE` | unchanged |

## 6. Test results

Executed 2026-07-30 immediately after the migration. Every test that mutates
data ran inside `BEGIN … ROLLBACK`; nothing was persisted.

Fixtures: admin `bcb8b223-3711-4d87-92c2-8d5d78f7e052` (`admin`),
sales `4c044d09-7ac0-4923-b47c-d75f3e6007c3` (`jack`).

| # | Test | Result | Status |
|---|---|---|---|
| T7 | sales changes own role `sales → admin` | `42501: permission denied: only an admin can change profiles.role` (`um_guard_profile_role()` line 17) | **PASS** |
| T7b | sales self-inserts `role='admin'` | `42501: permission denied: only an admin can create a profile with role admin` (line 33) | **PASS** |
| T8 | sales edits `display_name` / `avatar_url` / `username` | succeeded; `role` still `sales` | **PASS** |
| T8b | sales UPDATE re-stating the same `role='sales'` (no-op write) | succeeded — no false positive on whole-row upserts | **PASS** |
| T8d | `service_role` writes `role` (admin-create-user path) | succeeded | **PASS** |
| T8e | `postgres` writes `role` | succeeded | **PASS** |
| T8e-real | **real `handle_new_user()` path** — INSERT into `auth.users` with `raw_app_meta_data = {"role":"admin"}` | `on_auth_user_created` fired, profile `guardtest` created with `role='admin'` | **PASS** |
| T8f | `anon` UPDATE profiles | `42501: permission denied for table profiles` (grant revoked) | **PASS** |
| T8g | admin demotes **own** account `admin → sales` | `42501: permission denied: an admin cannot remove admin from their own account; promote another admin first, or use service_role for recovery` (line 25) | **PASS** |
| T8g2 | admin edits own `display_name` (no role change) | succeeded — guard does not over-block | **PASS** |
| T8h | admin changes **another** user's role (promote, then demote back) | succeeded in both directions | **PASS** |
| T8i | `service_role` recovery: demote admin, then restore | succeeded in both steps | **PASS** |
| T8j | fail-closed branch — untrusted role writing `profiles` | **not directly testable under current grants; unknown roles are denied at table privilege layer before trigger** | **NOT TESTED** |

### T8j — why it is not marked PASS

The `raise exception 'permission denied: unexpected execution role'` branch was
**never executed**, so it is recorded as NOT TESTED rather than PASS.

Attempts made:

- `SET ROLE dashboard_user` → `42501: permission denied to set role "dashboard_user"`.
  `postgres` is not a member of it.
- `postgres` can only assume `anon`, `authenticated`, `authenticator`,
  `service_role`, `supabase_privileged_role` (plus `pg_*` roles).
- `SET ROLE authenticator` → `42501: permission denied for table profiles`.
- `SET ROLE supabase_privileged_role` → `42501: permission denied for table profiles`.

Both untrusted roles reachable from this session are blocked at the **table
privilege layer**, before the trigger fires. In practice the branch is close to
unreachable for exactly that reason: any role that is not
`postgres`/`service_role`/`anon`/`authenticated` also lacks write grants on
`profiles`. It remains as defense in depth, but its behaviour is unverified by
execution.

### T8e methodology note

The first T8e attempt inserted directly into `public.profiles` as `postgres` and
returned `23503` (foreign key violation against `auth.users`) — that was **not**
the guard rejecting the write; the guard had already allowed it. The test was
redone two ways: a direct `postgres` role write, and a real insert into
`auth.users` so `handle_new_user()` ran on its own. The latter is the conclusive
evidence that the signup flow is unaffected.

## 7. Admin count before / after

| Metric | Before | After |
|---|---|---|
| `role = 'admin'` | **1** | **1** |
| `role = 'sales'` | 6 | 6 |
| total profiles | 7 | 7 |
| `md5(profiles: id+role+username+display_name)` | `0c2ecde11795f55791802f2d6c172047` | `0c2ecde11795f55791802f2d6c172047` |

The profiles checksum is byte-identical, confirming no row was altered by the
migration or left behind by any test.

**Admin login verified intact** — `admin@umhome.app`: `email_confirmed = true`,
`banned_until = null`, `deleted_at = null`, `encrypted_password` present, role
still `admin`.

**No test residue:** `leftover_profiles = 0`, `leftover_auth_users = 0`,
`leftover_display_names = 0` (checked for `regression_test`, `esc`, `newadmin`,
`guardtest`, `failclosed`, `Regression Test`, `Same Role Write`,
`Admin Self Edit`).

## 8. cars / car_images / R2 / image URLs unchanged

| Metric | Before | After |
|---|---|---|
| `cars` count | 286 | 286 |
| `md5(cars.cover_image_url)` | `36be202656fcadc87dcadd24ef246466` | `36be202656fcadc87dcadd24ef246466` |
| `car_images` count | 4966 | 4966 |
| `md5(car_images.image_url + storage_path)` | `8b946f290c230583865abb5139338b90` | `8b946f290c230583865abb5139338b90` |
| `md5(cars.status)` | `06cb20cc1fb944ad147189b2a6cb3952` | `06cb20cc1fb944ad147189b2a6cb3952` |

R2 was not contacted, no R2 key was read or written, and no edge function or
cron schedule was modified. This migration touches only `public.profiles`.

## 9. Outcome

Executed 2026-07-30. **Successful.** The confirmed privilege-escalation path is
closed: a `sales` user can no longer escalate to `admin` via either `UPDATE` or
self-`INSERT`, and the single existing admin account cannot demote itself into a
zero-admin lockout. Legitimate signup, admin user creation, admin role
management, and sales self-service profile edits all continue to work, each
verified by an executed test.

## 10. Known gaps / follow-ups

- Applied with `execute_sql`, not `apply_migration`, so **no row was added to
  Supabase migration history**. Needs backfilling if this project tracks schema
  history. (Same applies to Migration B.)
- **T8j is unverified** (§6). If the fail-closed branch is ever relied upon,
  it needs a test run from a role that holds write grants on `profiles` but is
  not in the trusted allowlist.
- Handing over admin rights now requires two steps: promote the new admin
  first, then have that admin (or `service_role`) demote the previous one. A
  sole admin can no longer step down through the UI. This is the intended
  effect of guard branch (b), but it is a real workflow change.
- `public.um_car_sales_events(uuid)` remains `SECURITY DEFINER` with `anon`
  EXECUTE. It is `STABLE` and writes nothing, but lets `anon` read any car's
  transaction history with RLS bypassed — data disclosure, out of scope here,
  not yet triaged.
