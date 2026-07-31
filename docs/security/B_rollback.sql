-- ============================================================================
-- ROLLBACK for Migration B — restores the exact pre-migration ACL
-- Status: DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- WARNING: this reopens the confirmed anon-writable RPC hole.
-- ============================================================================
-- Pre-migration ACL captured 2026-07-30 for BOTH functions:
--   =X/postgres | postgres=X/postgres | anon=X/postgres
--   | authenticated=X/postgres | service_role=X/postgres
-- "=X/postgres" is the PUBLIC grant, restored by GRANT ... TO PUBLIC below.
-- ============================================================================

BEGIN;

GRANT EXECUTE ON FUNCTION public.um_sync_all_car_sales_statuses()
  TO PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  TO PUBLIC, anon, authenticated;

-- Only needed if the OPTIONAL stricter variant was applied:
-- GRANT EXECUTE ON FUNCTION public.um_sync_all_car_sales_statuses()   TO service_role;
-- GRANT EXECUTE ON FUNCTION public.um_sync_one_car_sales_status(uuid) TO service_role;

COMMIT;
