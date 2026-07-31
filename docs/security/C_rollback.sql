-- ============================================================================
-- ROLLBACK for Phase 2b / Migration C
-- Restores the exact pre-migration policy on all three tables.
-- Status: DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- WARNING: this gives every authenticated user (including role='sales') full
--          INSERT/UPDATE/DELETE on cars, car_images and car_status_history
--          again. It reopens the exact gap Phase 2b closes.
-- ============================================================================
-- Pre-migration state captured read-only 2026-07-31 — identical on all three:
--   policy "umhome auth full"
--     FOR ALL TO authenticated USING (true) WITH CHECK (true)   [permissive]
-- ============================================================================

BEGIN;

-- cars
DROP POLICY IF EXISTS "cars select (authenticated)" ON public.cars;
DROP POLICY IF EXISTS "cars insert (admin)"         ON public.cars;
DROP POLICY IF EXISTS "cars update (admin)"         ON public.cars;
DROP POLICY IF EXISTS "cars delete (admin)"         ON public.cars;
CREATE POLICY "umhome auth full"
  ON public.cars FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- car_images
DROP POLICY IF EXISTS "car_images select (authenticated)" ON public.car_images;
DROP POLICY IF EXISTS "car_images insert (admin)"         ON public.car_images;
DROP POLICY IF EXISTS "car_images update (admin)"         ON public.car_images;
DROP POLICY IF EXISTS "car_images delete (admin)"         ON public.car_images;
CREATE POLICY "umhome auth full"
  ON public.car_images FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- car_status_history (append-only in migration C: only 2 policies to drop;
-- the UPDATE/DELETE drops are kept as harmless no-ops in case an earlier
-- 4-policy variant was ever applied)
DROP POLICY IF EXISTS "car_status_history select (authenticated)" ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history insert (admin)"         ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history update (admin)"         ON public.car_status_history;
DROP POLICY IF EXISTS "car_status_history delete (admin)"         ON public.car_status_history;
CREATE POLICY "umhome auth full"
  ON public.car_status_history FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

COMMIT;

-- Only needed if the OPTIONAL anon-grant revoke block in C was also applied:
-- BEGIN;
-- GRANT INSERT, UPDATE, DELETE ON TABLE public.cars               TO anon;
-- GRANT INSERT, UPDATE, DELETE ON TABLE public.car_images         TO anon;
-- GRANT INSERT, UPDATE, DELETE ON TABLE public.car_status_history TO anon;
-- COMMIT;
