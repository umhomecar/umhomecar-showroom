-- ============================================================================
-- TEST PLAN — run only AFTER approval, in this order
-- Every DML test is wrapped in BEGIN ... ROLLBACK so no data is persisted.
-- T0/T9 are pure SELECT and are the R2 / image-immutability evidence.
-- ============================================================================
-- Substitute before running:
--   :sales_uuid  = a profiles.id with role='sales'
--   :admin_uuid  = the profiles.id with role='admin' (there is exactly 1)
--   :car_uuid    = any public.cars.id
-- ============================================================================


-- ── T0. BASELINE (run BEFORE migrating; rerun as T9 after) ──────────────────
-- Must be byte-identical before and after. This is the proof that R2 keys,
-- cover_image_url, image_url and storage_path were untouched.
SELECT count(*) AS cars_n,
       md5(string_agg(coalesce(cover_image_url,''), '|' ORDER BY id::text)) AS cover_md5
FROM public.cars;

SELECT count(*) AS imgs_n,
       md5(string_agg(coalesce(image_url,'') || '#' || coalesce(storage_path,''), '|' ORDER BY id::text)) AS img_md5
FROM public.car_images;

SELECT status, count(*) FROM public.cars GROUP BY status ORDER BY 1;
SELECT role, count(*) FROM public.profiles GROUP BY role ORDER BY 1;


-- ============================================================================
-- MIGRATION B TESTS
-- ============================================================================

-- ── T1. anon EXECUTE on um_sync_all → must FAIL ─────────────────────────────
-- EXPECT: ERROR 42501 permission denied for function um_sync_all_car_sales_statuses
BEGIN;
  SET LOCAL ROLE anon;
  SELECT * FROM public.um_sync_all_car_sales_statuses();
ROLLBACK;

-- ── T2. anon EXECUTE on um_sync_one(uuid) → must FAIL ───────────────────────
-- EXPECT: ERROR 42501 permission denied for function um_sync_one_car_sales_status
BEGIN;
  SET LOCAL ROLE anon;
  SELECT public.um_sync_one_car_sales_status(':car_uuid'::uuid);
ROLLBACK;

-- ── T3. authenticated (sales) EXECUTE → must FAIL ───────────────────────────
-- POLICY CHOICE: authenticated is revoked, not retained.
-- Rationale: grep over admin.html / index.html / showroom-color-addon.js found
-- ZERO references to either function; the front end only calls
-- is_showroom_admin, get_showroom_favorite_counts, bump_car_view,
-- sync_showroom_favorites, set_showroom_favorite. No client workflow — sales
-- or admin — invokes these RPCs today, so revoking removes no capability.
-- EXPECT: ERROR 42501 for both
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT * FROM public.um_sync_all_car_sales_statuses();
ROLLBACK;

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  SELECT public.um_sync_one_car_sales_status(':car_uuid'::uuid);
ROLLBACK;
-- NOTE: this fails for an ADMIN too. That is intended and is not a regression,
-- because no admin UI path calls it. If you later want an admin-triggered
-- resync, the correct fix is a new guarded wrapper RPC
-- (is_admin() check + GRANT to authenticated), NOT re-granting these.

-- ── T4. service_role EXECUTE → must still SUCCEED ───────────────────────────
-- EXPECT: returns 1 row (total_cars, sold, approved, booked, available)
BEGIN;
  SET LOCAL ROLE service_role;
  SELECT * FROM public.um_sync_all_car_sales_statuses();
ROLLBACK;

-- ── T5. legitimate trigger path → must still SUCCEED ────────────────────────
-- The whole point of B: revoking end-user EXECUTE must NOT break
-- trg_um_sync_transaction_car_statuses, because um_sync_transaction_car_statuses()
-- is SECURITY DEFINER owned by postgres, so EXECUTE is checked against postgres.
-- EXPECT: no permission error; cars.status/sales_status_updated_at recomputed.
BEGIN;
  SELECT id, status, sold_at, sales_status_synced, sales_status_updated_at
  FROM public.cars WHERE id = ':car_uuid'::uuid;

  -- Touch one transaction row for this car to fire the AFTER trigger.
  -- Self-assignment of car_id: guaranteed-existing column, no value change,
  -- still fires FOR EACH ROW AFTER UPDATE. (Postgres UPDATE has no LIMIT,
  -- hence the subquery.)
  UPDATE public.transactions
     SET car_id = car_id
   WHERE id = (
     SELECT id FROM public.transactions
      WHERE car_id = ':car_uuid'::uuid AND deleted_at IS NULL
      LIMIT 1
   );

  SELECT id, status, sold_at, sales_status_synced, sales_status_updated_at
  FROM public.cars WHERE id = ':car_uuid'::uuid;
ROLLBACK;

-- ── T6. showroom read path → must still SUCCEED ─────────────────────────────
-- EXPECT: rows returned, identical shape/count to pre-migration.
-- Migration B changes no table/view/policy grants, so this must be unaffected.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT count(*) FROM public.public_cars;
  SELECT * FROM public.public_cars LIMIT 5;
ROLLBACK;


-- ============================================================================
-- MIGRATION A TESTS
-- ============================================================================

-- ── T7. sales escalating own role → must FAIL ───────────────────────────────
-- EXPECT: ERROR 42501 'permission denied: only an admin can change profiles.role'
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  UPDATE public.profiles SET role = 'admin' WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T7b. sales self-inserting an admin profile → must FAIL ──────────────────
-- EXPECT: ERROR — blocked by the tightened INSERT policy (RLS violation) or by
-- the guard trigger, whichever fires first. Either is a pass.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  INSERT INTO public.profiles (id, username, display_name, role)
  VALUES (':sales_uuid'::uuid, 'esc', 'esc', 'admin');
ROLLBACK;

-- ── T8. sales editing normal profile fields → must SUCCEED ──────────────────
-- This is the regression test for "sales ยังแก้ field profile ปกติได้"
-- EXPECT: UPDATE 1, no error
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  UPDATE public.profiles
     SET display_name = 'Regression Test',
         avatar_url   = 'https://example.invalid/a.png',
         username     = 'regression_test'
   WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T8b. sales UPDATE that re-states the SAME role → must SUCCEED ───────────
-- Guards against a false positive: the trigger compares OLD vs NEW, so a
-- no-op role write (common with client-side upsert of a whole row) must pass.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  UPDATE public.profiles
     SET display_name = 'Same Role Write', role = 'sales'
   WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T8c. admin changing ANOTHER user's role → must SUCCEED ──────────────────
-- Requirement: "admin เดิมยังสามารถเปลี่ยน role ของคนอื่นได้"
-- EXPECT: UPDATE 1, no error
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  UPDATE public.profiles SET role = 'admin' WHERE id = ':sales_uuid'::uuid;
  SELECT id, role FROM public.profiles WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T8d. service_role role write → must SUCCEED (admin-create-user path) ────
-- The admin-create-user edge function upserts profiles.role as service_role.
-- If this fails, that edge function is broken — hard stop, roll back A.
BEGIN;
  SET LOCAL ROLE service_role;
  UPDATE public.profiles SET role = 'admin' WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T8e. handle_new_user() path → must SUCCEED ──────────────────────────────
-- SECURITY DEFINER (owner postgres) INSERT of a non-'sales' role must not be
-- blocked by the guard. Simulated by inserting as postgres.
BEGIN;
  INSERT INTO public.profiles (id, username, display_name, role)
  VALUES (gen_random_uuid(), 'newadmin', 'New Admin', 'admin');
ROLLBACK;

-- ── T8f. anon write on profiles → must FAIL ─────────────────────────────────
-- EXPECT: ERROR 42501 permission denied for table profiles (grant revoked).
-- Before the migration this failed on RLS instead; either way anon never wrote.
BEGIN;
  SET LOCAL ROLE anon;
  UPDATE public.profiles SET role = 'admin' WHERE id = ':sales_uuid'::uuid;
ROLLBACK;


-- ── T8g. admin demoting THEIR OWN account admin -> sales → must FAIL ────────
-- Last-admin lockout guard. There is exactly 1 admin, so this would otherwise
-- leave the system with zero admins and no UI path back.
-- EXPECT: ERROR 42501 'an admin cannot remove admin from their own account...'
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  UPDATE public.profiles SET role = 'sales' WHERE id = ':admin_uuid'::uuid;
ROLLBACK;

-- ── T8g2. admin editing their own NON-role fields → must SUCCEED ────────────
-- Guards against over-blocking: the self-demotion rule must only trigger on a
-- role change, not on ordinary self-edits by the admin.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  UPDATE public.profiles
     SET display_name = 'Admin Self Edit'
   WHERE id = ':admin_uuid'::uuid;
ROLLBACK;

-- ── T8h. admin changing ANOTHER user's role → must SUCCEED ──────────────────
-- Requested by name. Same assertion as T8c above; kept separate so the
-- self-demotion guard is proven not to have broken normal admin role
-- management. Run both directions.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  UPDATE public.profiles SET role = 'admin' WHERE id = ':sales_uuid'::uuid;  -- promote
  SELECT id, role FROM public.profiles WHERE id = ':sales_uuid'::uuid;
  UPDATE public.profiles SET role = 'sales' WHERE id = ':sales_uuid'::uuid;  -- demote back
  SELECT id, role FROM public.profiles WHERE id = ':sales_uuid'::uuid;
ROLLBACK;

-- ── T8i. service_role recovery path → must SUCCEED ──────────────────────────
-- If the self-demotion guard ever needs to be overridden (handover, or an
-- admin account must genuinely be demoted), service_role must still be able
-- to do it. This is the documented escape hatch — if it fails, the guard is
-- too strict and A must be rolled back.
BEGIN;
  SET LOCAL ROLE service_role;
  UPDATE public.profiles SET role = 'sales' WHERE id = ':admin_uuid'::uuid;  -- demote admin
  SELECT id, role FROM public.profiles WHERE id = ':admin_uuid'::uuid;
  UPDATE public.profiles SET role = 'admin' WHERE id = ':admin_uuid'::uuid;  -- restore
  SELECT id, role FROM public.profiles WHERE id = ':admin_uuid'::uuid;
ROLLBACK;


-- ── T8j. fail-closed branch: an untrusted role writing profiles ─────────────
-- STATUS 2026-07-30: NOT TESTED — not directly testable under current grants;
-- unknown roles are denied at the table privilege layer before the trigger.
-- The 'permission denied: unexpected execution role' branch has NEVER been
-- executed. Do not record this as PASS.
--
-- Attempts made, all blocked before reaching the trigger:
--   SET ROLE dashboard_user           -> 42501 permission denied to set role
--                                        (postgres is not a member)
--   SET ROLE authenticator            -> 42501 permission denied for table profiles
--   SET ROLE supabase_privileged_role -> 42501 permission denied for table profiles
--
-- postgres can only assume: anon, authenticated, authenticator, service_role,
-- supabase_privileged_role (plus pg_* roles).
--
-- To actually exercise the branch, a role is needed that BOTH holds write
-- grants on public.profiles AND is outside the trusted allowlist
-- (postgres, service_role) and outside anon/authenticated. No such role exists
-- in this project today.
--
-- BEGIN;
--   SET LOCAL ROLE <untrusted_role_with_profiles_write_grant>;
--   UPDATE public.profiles SET display_name = 'failclosed' WHERE id = ':sales_uuid'::uuid;
--   -- EXPECT: ERROR 42501 'permission denied: unexpected execution role'
-- ROLLBACK;


-- ── T9. RERUN T0 — must be byte-identical to the baseline ───────────────────
-- Any difference in cover_md5 / img_md5 means something touched images:
-- STOP and roll back.
