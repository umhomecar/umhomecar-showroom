-- ============================================================================
-- ROLLBACK for Migration D
-- Status: DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- ============================================================================
-- Safe to run: it only drops the NEW wrapper. It does not touch
-- um_sync_all_car_sales_statuses(), whose ACL stays
--   postgres=X/postgres | service_role=X/postgres
--
-- CONSEQUENCE: the Data Health "sync statuses" button returns to being broken
-- for admins (42501), i.e. back to the current state. Roll back the frontend
-- change alongside this, or leave the frontend pointing at the wrapper — it
-- will simply fail with "function does not exist" instead.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.um_admin_sync_all_car_sales_statuses();

COMMIT;
