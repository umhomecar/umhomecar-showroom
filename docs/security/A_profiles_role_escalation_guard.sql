-- ============================================================================
-- Migration A — profiles role privilege escalation guard
-- Project : jvvjwblwdeggetnpfvgq
-- Scope   : public.profiles ONLY. Does not touch cars / car_images / R2 /
--           cover_image_url / image_url / storage_path / edge functions.
-- Status  : DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- ============================================================================
-- Confirmed vulnerability:
--   RLS policy "profiles update (admin or self)" (FOR UPDATE, role authenticated)
--     USING      : (is_admin() OR (id = auth.uid()))
--     WITH CHECK : (is_admin() OR (id = auth.uid()))
--   No column restriction, and `authenticated` holds table-level UPDATE on the
--   `role` column. A `sales` user can therefore run:
--     UPDATE profiles SET role='admin' WHERE id = auth.uid();
--   RLS policy "profiles insert (admin)" (FOR INSERT) has the same gap:
--     WITH CHECK (is_admin() OR (id = auth.uid()))  -- self-insert with role='admin'
--
-- Why a trigger and not a column-level REVOKE:
--   Admins authenticate through PostgREST as the SAME `authenticated` role as
--   sales users. REVOKE UPDATE(role) ON profiles FROM authenticated would block
--   admins too, breaking legitimate role management. A trigger can distinguish
--   admin from non-admin at row level; a column grant cannot.
--
-- Why the guard must bypass non-PostgREST callers:
--   public.handle_new_user()  -> SECURITY DEFINER, owner postgres, INSERTs
--                                profiles with role from raw_app_meta_data
--   edge fn admin-create-user -> upserts profiles.role using service_role
--   Both are legitimate and must keep working, so the guard only enforces for
--   the two browser-reachable PostgREST roles: anon and authenticated.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Guard function: block role changes made by non-admin end users
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.um_guard_profile_role()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- Fail-closed role handling.
  --
  -- (i) Explicitly trusted execution roles bypass the guard. This list is a
  --     closed allowlist of roles verified against this project:
  --       postgres     - owner of handle_new_user() and every SECURITY DEFINER
  --                      function; also the role cron and migrations run as
  --       service_role - the admin-create-user edge function, and the
  --                      documented recovery path (see T8i)
  if current_user in ('postgres', 'service_role') then
    return new;
  end if;

  -- (ii) The two browser-reachable PostgREST roles fall through to the role
  --      rules below.
  --
  -- (iii) Anything else is rejected rather than silently exempted, so a DB
  --       role added in the future cannot bypass this guard by default.
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
      --     There is currently exactly 1 admin, so a self-demotion would
      --     leave the system with no admin and no way back through the UI.
      --     Recovery path if this ever needs to be forced: service_role or
      --     postgres, both of which are exempt by the current_user check above.
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

-- ---------------------------------------------------------------------------
-- OPERATIONAL NOTE — fail-closed role list
-- This project has 16 DB roles. Only postgres and service_role are trusted;
-- anon and authenticated are subject to the rules; the remaining 12 now raise
-- 42501 if they ever write public.profiles. Two of them are real platform
-- roles, not hypothetical future roles:
--     supabase_admin  (superuser, used by platform maintenance / restores)
--     dashboard_user  (some Supabase dashboard operations)
-- If a restore or platform operation writes profiles as one of these, it will
-- now fail. Note pg_restore and logical replication usually set
-- session_replication_role='replica', which disables this trigger entirely,
-- so the practical exposure is limited but not zero.
-- To trust them as well, change the allowlist on line ~50 to:
--     if current_user in ('postgres','service_role','supabase_admin','dashboard_user') then
-- Flagged for an explicit decision; left as approved (postgres, service_role only).
--
-- Verified NOT affected: supabase_auth_admin (GoTrue). It inserts into
-- auth.users, and the profiles INSERT happens inside handle_new_user(), which
-- is SECURITY DEFINER owned by postgres, so current_user is postgres there.
-- ---------------------------------------------------------------------------
COMMENT ON FUNCTION public.um_guard_profile_role() IS
  'Blocks profiles.role escalation by non-admin PostgREST callers (anon/authenticated), and blocks an admin from removing admin from their own account (last-admin lockout guard). Exempts postgres/service_role so handle_new_user() and the admin-create-user edge function keep working, and so service_role remains a recovery path.';

-- Name sorts before trg_profiles_updated, so the guard runs first.
DROP TRIGGER IF EXISTS trg_profiles_guard_role ON public.profiles;
CREATE TRIGGER trg_profiles_guard_role
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.um_guard_profile_role();

-- ---------------------------------------------------------------------------
-- 2) Tighten the INSERT policy (defense in depth, no recursion risk:
--    the check compares NEW.role to a literal, it does not read profiles)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "profiles insert (admin)" ON public.profiles;
CREATE POLICY "profiles insert (admin)"
  ON public.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (id = auth.uid() AND role = 'sales')
  );

-- NOTE: the UPDATE policy "profiles update (admin or self)" is deliberately
-- left UNCHANGED. Sales users keep updating username / display_name /
-- avatar_url on their own row exactly as before; only the role column is now
-- constrained, and that is enforced by the trigger above.

-- ---------------------------------------------------------------------------
-- 3) Remove unused write grants held by anon on profiles
--    (RLS already blocks anon today — there is no anon policy — but the raw
--     grant is unnecessary attack surface. Table-scoped only; this does NOT
--     alter schema-wide DEFAULT PRIVILEGES.)
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE ON TABLE public.profiles FROM anon;

COMMIT;
