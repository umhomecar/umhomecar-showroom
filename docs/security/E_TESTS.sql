-- ============================================================================
-- TEST PLAN — Migration E (revoke um_car_sales_events)
-- Run only AFTER approval, in this order. Every DML test is wrapped in
-- BEGIN … ROLLBACK so nothing is persisted.
-- ============================================================================
-- Fixtures (live, captured read-only 2026-07-31):
--   :admin_uuid = bcb8b223-3711-4d87-92c2-8d5d78f7e052   (username 'admin')
--   :sales_uuid = 4c044d09-7ac0-4923-b47c-d75f3e6007c3   (username 'jack')
--   :car_uuid   = b86b3eec-94a5-45af-ad18-a910f98e9641   (29 transactions;
--                 returns 8 event rows today, so a broken chain is visible)
-- ============================================================================


-- ── E0. BASELINE — run BEFORE the migration, rerun as E9 ────────────────────
-- Recapture live rather than trusting an older number: the cron job
-- auto-delete-sold-cars-daily runs 20:30 UTC daily and staff edit continuously.
-- Values at the 2026-07-31 16:21 Asia/Bangkok capture, for reference only:
--   cars_n 288 | car_images_n 5005 | public_cars_n 244
--   cover_image_url_md5        da4bd4518a61c414196a1ee71ba0accf
--   image_url_storage_path_md5 e91f79830d83c15acfd063a26f714e7f
SELECT now() AT TIME ZONE 'Asia/Bangkok' AS captured_at_th,
       (SELECT count(*) FROM public.cars) AS cars_n,
       (SELECT count(*) FROM public.car_images) AS car_images_n,
       (SELECT count(*) FROM public.public_cars) AS public_cars_n,
       (SELECT md5(string_agg(coalesce(cover_image_url,''),'|' ORDER BY id::text)) FROM public.cars) AS cover_image_url_md5,
       (SELECT md5(string_agg(coalesce(image_url,'')||'#'||coalesce(storage_path,''),'|' ORDER BY id::text)) FROM public.car_images) AS image_url_storage_path_md5,
       (SELECT md5(string_agg(status||':'||id::text,'|' ORDER BY id::text)) FROM public.cars) AS cars_status_md5;

-- Function fingerprint before. EXPECT:
--   body_md5        333aaabf6a19b7d20f324b8ebab94e75
--   functiondef_md5 e38be4ff97e6dd1d588879ed5e66fb79
--   acl             =X/postgres | postgres=X/postgres | anon=X/postgres
--                   | authenticated=X/postgres | service_role=X/postgres
SELECT p.proname,
       md5(p.prosrc)               AS body_md5,
       md5(pg_get_functiondef(p.oid)) AS functiondef_md5,
       coalesce(array_to_string(p.proacl,' | '),'NULL(PUBLIC)') AS acl
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'um_car_sales_events';

-- Reference: what anon can see BEFORE the migration (this is the disclosure).
-- EXPECT: 8 rows of booking/approval/delivery history.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT count(*) AS anon_event_rows_before
  FROM public.um_car_sales_events(':car_uuid'::uuid);
ROLLBACK;


-- ============================================================================
-- AFTER MIGRATION E
-- ============================================================================

-- ── E1. anon calls the function → must FAIL ─────────────────────────────────
-- EXPECT: ERROR 42501 permission denied for function um_car_sales_events
BEGIN;
  SET LOCAL ROLE anon;
  SELECT * FROM public.um_car_sales_events(':car_uuid'::uuid);
ROLLBACK;

-- ── E2. authenticated (sales) calls the function → must FAIL ────────────────
-- EXPECT: ERROR 42501 permission denied for function um_car_sales_events
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT * FROM public.um_car_sales_events(':car_uuid'::uuid);
ROLLBACK;

-- ── E2b. authenticated (ADMIN) calls the function → must FAIL ───────────────
-- Intentional: no UI path calls this directly, so admins lose nothing. Stated
-- explicitly so the failure is not later mistaken for a regression.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  SELECT * FROM public.um_car_sales_events(':car_uuid'::uuid);
ROLLBACK;

-- ── E3. service_role calls the function → must FAIL ─────────────────────────
-- EXPECT: ERROR 42501 permission denied for function um_car_sales_events
BEGIN;
  SET LOCAL ROLE service_role;
  SELECT * FROM public.um_car_sales_events(':car_uuid'::uuid);
ROLLBACK;

-- ── E4. internal um_sync_one_car_sales_status → must SUCCEED ────────────────
-- The definer chain must still reach um_car_sales_events. Run as service_role,
-- which (a) can execute um_sync_one, and (b) has just been revoked on
-- um_car_sales_events — so a pass here proves EXECUTE is checked against the
-- definer, not the caller.
-- EXPECT: completes with no permission error.
BEGIN;
  SET LOCAL ROLE service_role;
  SELECT public.um_sync_one_car_sales_status(':car_uuid'::uuid);
  SELECT 'sync_one_ok' AS result, id, status, sales_status_synced
  FROM public.cars WHERE id = ':car_uuid'::uuid;
ROLLBACK;

-- ── E5. internal um_sync_all_car_sales_statuses → must SUCCEED ──────────────
-- EXPECT: 1 row (total_cars, sold, approved, booked, available), no error.
BEGIN;
  SET LOCAL ROLE service_role;
  SELECT * FROM public.um_sync_all_car_sales_statuses();
ROLLBACK;

-- ── E5b. admin wrapper (Migration D) → must SUCCEED ─────────────────────────
-- The Data Health button reaches um_car_sales_events through two nested
-- definer hops. Regression guard for the fix that was just shipped to prod.
-- EXPECT: 1 row, no error.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  SELECT * FROM public.um_admin_sync_all_car_sales_statuses();
ROLLBACK;

-- ── E6. transaction trigger sync → must SUCCEED ─────────────────────────────
-- Deliberately run as a SALES identity: that user can write transactions
-- ("umhome auth full" on transactions is unchanged) but now has NO execute on
-- um_car_sales_events. The AFTER trigger fires
-- um_sync_transaction_car_statuses() -> um_sync_one_car_sales_status()
-- -> um_car_sales_events(), all SECURITY DEFINER owned by postgres.
-- EXPECT: no permission error. (This is the same methodology error that had to
-- be corrected during Migration B — running it as postgres would prove nothing.)
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  UPDATE public.transactions
     SET car_id = car_id
   WHERE id = (SELECT id FROM public.transactions
                WHERE car_id = ':car_uuid'::uuid AND deleted_at IS NULL LIMIT 1);
  SELECT 'trigger_ok' AS result, id, status, sales_status_synced
  FROM public.cars WHERE id = ':car_uuid'::uuid;
ROLLBACK;

-- ── E7. function body unchanged + ACL matches desired state ─────────────────
-- EXPECT:
--   body_md5        333aaabf6a19b7d20f324b8ebab94e75   (IDENTICAL to E0)
--   functiondef_md5 e38be4ff97e6dd1d588879ed5e66fb79   (IDENTICAL to E0)
--   acl             postgres=X/postgres
--   anon=false, authenticated=false, service_role=false, postgres=true
-- Any change in either md5 means the body was touched: STOP and roll back.
SELECT p.proname,
       md5(p.prosrc)                  AS body_md5,
       md5(pg_get_functiondef(p.oid)) AS functiondef_md5,
       coalesce(array_to_string(p.proacl,' | '),'NULL(PUBLIC)') AS acl,
       has_function_privilege('anon',         p.oid,'EXECUTE') AS anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
       has_function_privilege('service_role', p.oid,'EXECUTE') AS service_role,
       has_function_privilege('postgres',     p.oid,'EXECUTE') AS postgres_owner,
       p.prosecdef, pg_get_userbyid(p.proowner) AS owner,
       array_to_string(p.proconfig,',') AS config
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'um_car_sales_events';

-- ── E8. nothing else was touched (pure SELECT) ──────────────────────────────
-- Migration E is scoped to one function; these must be unchanged.
-- EXPECT: um_sync_all -> postgres=X | service_role=X
--         um_admin_sync_all -> postgres=X | authenticated=X
--         um_sync_one, um_sync_transaction_car_statuses -> unchanged from before
SELECT p.proname,
       coalesce(array_to_string(p.proacl,' | '),'NULL(PUBLIC)') AS acl,
       md5(p.prosrc) AS body_md5
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('um_sync_one_car_sales_status',
                    'um_sync_all_car_sales_statuses',
                    'um_admin_sync_all_car_sales_statuses',
                    'um_sync_transaction_car_statuses')
ORDER BY 1;
-- um_sync_all_car_sales_statuses body_md5 must stay b59d1f522905cb3c314a857c80e73c93

-- ── E8b. anon showroom read path → must SUCCEED, unchanged ──────────────────
-- public_cars is owned by postgres with security_invoker unset, so it bypasses
-- RLS on cars and is unaffected. Count must equal E0's public_cars_n.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT count(*) AS anon_public_cars FROM public.public_cars;
ROLLBACK;


-- ── E9. RERUN E0 — cars / car_images / R2 / image URLs unchanged ────────────
-- cover_image_url_md5 and image_url_storage_path_md5 MUST be byte-identical to
-- E0. Any difference means an image URL or storage path moved: STOP and roll
-- back. (cars_status_md5 may legitimately differ if a real user edit or a sync
-- landed between captures — it is informational, not a gate.)
