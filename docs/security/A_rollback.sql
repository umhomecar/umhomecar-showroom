-- ============================================================================
-- ROLLBACK for Migration A — restores the exact pre-migration state
-- Status: DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- WARNING: this reopens the confirmed privilege-escalation hole.
-- ============================================================================

BEGIN;

-- 1) Remove the guard
DROP TRIGGER IF EXISTS trg_profiles_guard_role ON public.profiles;
DROP FUNCTION IF EXISTS public.um_guard_profile_role();

-- 2) Restore the original INSERT policy verbatim
--    (original: FOR INSERT, TO authenticated, WITH CHECK (is_admin() OR (id = auth.uid())))
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
