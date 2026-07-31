-- ============================================================================
-- Phase 2b / Migration C — cars + car_images + car_status_history
--   sales: SELECT only.  admin: full CRUD.
-- Project : jvvjwblwdeggetnpfvgq
-- Status  : DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- Scope   : RLS policies on 3 tables. No table grants changed, no function
--           bodies, no data, no R2, no image URL columns, no edge functions,
--           no cron.
-- ============================================================================
-- CURRENT LIVE STATE (captured read-only 2026-07-31):
--   cars               RLS on, force off, 1 policy
--   car_images         RLS on, force off, 1 policy
--   car_status_history RLS on, force off, 1 policy
--   All three: policy "umhome auth full"
--       FOR ALL TO authenticated USING (true) WITH CHECK (true)
--   => every authenticated user, including role='sales', currently has full
--      INSERT/UPDATE/DELETE on all three tables.
--   No anon policy exists on any of them, so anon is already denied by RLS
--   (it holds raw table grants, but RLS has no permissive policy for it).
--
-- WHY THIS IS ENFORCEABLE AT THE RLS LAYER:
--   The three "atomic" RPCs the frontend calls
--     um_set_car_status_atomic / um_delete_car_images_atomic /
--     um_reorder_car_images_atomic
--   DO NOT EXIST in this database (verified: no match in pg_proc, any schema).
--   src/api/cars.js catches PGRST202 via isMissingRpc() and falls back to
--   direct table DML. So 100% of frontend car writes are plain INSERT/UPDATE/
--   DELETE against these tables and are fully governed by RLS. There is no
--   SECURITY DEFINER bypass path to work around.
--
-- WHAT IS DELIBERATELY UNAFFECTED:
--   public showroom  - reads public.public_cars, a view owned by postgres with
--                      reloptions = NULL (security_invoker NOT set), so it runs
--                      with owner privileges and bypasses RLS on cars entirely.
--                      Verified the showroom queries only public_cars /
--                      car_view_ranking / showroom_settings / showroom_leads —
--                      never cars or car_images directly.
--   trigger sync     - um_sync_transaction_car_statuses() -> um_sync_one_car_
--                      sales_status() are SECURITY DEFINER owned by postgres,
--                      which has rolbypassrls, so they bypass these policies.
--   um_fix_missing_covers() - SECURITY DEFINER owned by postgres (bypasses RLS)
--                      and already carries its own um_is_admin() guard.
--   service_role     - has rolbypassrls; edge functions unaffected.
--   R2 worker        - /__admin/migrate PATCHes cars/car_images using the
--                      calling ADMIN's JWT, so it passes is_admin() and keeps
--                      working. /__maintenance/delete uses a token + service
--                      role and is unaffected.
--
-- NOTE ON is_admin():
--   public.is_admin() is STABLE SECURITY DEFINER and reads public.profiles.
--   It does not read cars/car_images, so there is no RLS recursion.
--   It is wrapped in a scalar subquery below so Postgres evaluates it once per
--   statement (InitPlan) instead of once per row — matters on car_images
--   (~4,966 rows).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- cars
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- car_images
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- car_status_history — APPEND-ONLY (2 policies, not 4)
--
--   authenticated SELECT : allowed (the timeline view is reachable by sales;
--                          cs-timeline is not in SALES_BLOCKED)
--   admin INSERT         : allowed (setCarStatus() writes one row per status
--                          change, alongside the cars UPDATE)
--   UPDATE               : NO POLICY — nobody can rewrite history
--   DELETE               : NO POLICY — nobody can erase history
--
-- Verified before choosing append-only:
--   * The only code reference anywhere is an INSERT:
--       umhome-summary-web/src/api/cars.js:167
--         .from('car_status_history').insert({ car_id, old_status, new_status, note })
--     inside setCarStatus()'s fallback path. No UPDATE and no DELETE against
--     this table exists in either repository.
--   * No database trigger exists on car_status_history, and no database
--     function references it (pg_trigger + pg_proc.prosrc both empty).
--   * Rows are still removed when their car is deleted, via
--       car_status_history_car_id_fkey
--       FOREIGN KEY (car_id) REFERENCES cars(id) ON DELETE CASCADE
--     A referential-action cascade is performed by the system, NOT as the
--     invoking user, so it is not subject to RLS and does not need a DELETE
--     policy. hardDeleteCar() therefore keeps working — test C16 proves it.
--
--   Net effect: an audit trail that can be appended to and read, but never
--   silently altered — including by an admin, and including by a compromised
--   admin session.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "umhome auth full" ON public.car_status_history;

CREATE POLICY "car_status_history select (authenticated)"
  ON public.car_status_history FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "car_status_history insert (admin)"
  ON public.car_status_history FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.is_admin()));

-- Deliberately NO update policy and NO delete policy on car_status_history.
-- With RLS enabled and no permissive policy for a command, that command is
-- denied for every role subject to RLS. Do not add them without re-reviewing
-- the append-only decision.

COMMIT;


-- ============================================================================
-- OPTIONAL, NOT PART OF THE APPROVED DESIRED STATE — decide separately.
-- anon currently holds raw INSERT/UPDATE/DELETE grants on all three tables.
-- RLS already denies anon (no anon policy exists), so this changes no
-- behaviour; it only removes unused surface, the same way Migration A did for
-- profiles. The public showroom reads public_cars (owner-privileged view), so
-- revoking anon's direct grants on these tables does not affect it.
-- Left commented out because you did not list it in the desired access matrix.
-- ============================================================================
-- BEGIN;
-- REVOKE INSERT, UPDATE, DELETE ON TABLE public.cars               FROM anon;
-- REVOKE INSERT, UPDATE, DELETE ON TABLE public.car_images         FROM anon;
-- REVOKE INSERT, UPDATE, DELETE ON TABLE public.car_status_history FROM anon;
-- COMMIT;
