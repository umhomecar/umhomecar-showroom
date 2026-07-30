-- ============================================================================
-- Migration B — revoke anon/PUBLIC exposure of dangerous SECURITY DEFINER RPCs
-- Project : jvvjwblwdeggetnpfvgq
-- Scope   : EXECUTE privileges ONLY. Function bodies are NOT modified.
--           Does not touch cars data / car_images / R2 / cover_image_url /
--           image_url / storage_path / edge functions / cron.
-- Status  : DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- ============================================================================
-- Confirmed vulnerability:
--   public.um_sync_all_car_sales_statuses()   SECURITY DEFINER, owner postgres
--   public.um_sync_one_car_sales_status(uuid) SECURITY DEFINER, owner postgres
--   Both are granted EXECUTE to PUBLIC + anon + authenticated, and neither body
--   contains auth.uid(), is_admin(), um_is_admin() or any other guard.
--   postgres has rolbypassrls=true and public.cars has relforcerowsecurity=false,
--   so these functions write public.cars with RLS fully bypassed.
--   The anon key is embedded in the public index.html, so any internet caller
--   can POST /rest/v1/rpc/um_sync_all_car_sales_statuses and mutate cars.
--
-- Why privileges alone are sufficient (no body change needed):
--   The only legitimate caller is the trigger function
--   public.um_sync_transaction_car_statuses(), which is itself SECURITY DEFINER
--   owned by postgres. EXECUTE is therefore checked against postgres (the
--   definer), not against the invoking end user. Revoking anon/authenticated
--   does not affect the trigger path.
-- ============================================================================

BEGIN;

-- um_sync_all_car_sales_statuses() — no caller requires end-user EXECUTE
REVOKE ALL ON FUNCTION public.um_sync_all_car_sales_statuses()
  FROM PUBLIC, anon, authenticated;

-- um_sync_one_car_sales_status(uuid) — reached only via the SECURITY DEFINER
-- trigger function and via um_sync_all_car_sales_statuses()
REVOKE ALL ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  FROM PUBLIC, anon, authenticated;

-- Explicit desired end state. service_role already holds EXECUTE today, so
-- these GRANTs are no-ops against current production — they are stated
-- explicitly so the final ACL is declared by this migration rather than
-- inherited, and so re-running the file is idempotent.
GRANT EXECUTE ON FUNCTION public.um_sync_all_car_sales_statuses()
  TO service_role;

GRANT EXECUTE ON FUNCTION public.um_sync_one_car_sales_status(uuid)
  TO service_role;

-- Retained deliberately:
--   postgres     — function owner; required by the SECURITY DEFINER trigger path
--   service_role — not browser-reachable; keeps a manual/internal resync path
--                  open for maintenance without a further migration
--
-- Resulting ACL for both functions:
--   postgres=X/postgres | service_role=X/postgres
COMMIT;

-- (The previously drafted "optional stricter variant" that also revoked
--  service_role has been removed: retaining service_role EXECUTE is now the
--  explicitly approved desired state, declared by the GRANTs above.)
