-- ============================================================================
-- ROLLBACK for Migration E
-- Restores the exact pre-migration ACL of public.um_car_sales_events(uuid).
-- Status: DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- WARNING: this reopens the confirmed unauthenticated information disclosure.
--          Anyone holding the publishable key regains the ability to read any
--          car's booking / approval / delivery history with RLS bypassed.
-- ============================================================================
-- Pre-migration ACL, captured read-only 2026-07-31:
--   =X/postgres | postgres=X/postgres | anon=X/postgres
--   | authenticated=X/postgres | service_role=X/postgres
--
-- "=X/postgres" is the PUBLIC grant, restored by GRANT ... TO PUBLIC below.
-- Note that granting to PUBLIC alone would already make the function callable
-- by anon, authenticated and service_role; the explicit per-role grants are
-- included so the restored ACL matches the captured string entry for entry.
-- ============================================================================

BEGIN;

GRANT EXECUTE ON FUNCTION public.um_car_sales_events(uuid)
  TO PUBLIC, anon, authenticated, service_role;

COMMIT;

-- Verify after rollback — should match the pre-migration ACL exactly:
--   SELECT array_to_string(proacl,' | ')
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.proname = 'um_car_sales_events';
