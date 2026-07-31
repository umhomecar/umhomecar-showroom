-- ============================================================================
-- TEST PLAN — Migration C (Phase 2b)
--   cars / car_images / car_status_history: sales SELECT-only, admin full CRUD
-- Run only AFTER approval. Every DML test is wrapped in BEGIN … ROLLBACK.
-- ============================================================================
-- NO BASELINE VALUES ARE HARDCODED IN THIS FILE, BY DESIGN.
--
-- Counts and checksums drift continuously: the cron job
-- auto-delete-sold-cars-daily runs at 20:30 UTC every day, and staff add and
-- edit cars and images throughout the working day. Any number written into
-- this file is stale the moment it is written, and a stale expectation either
-- fails a healthy migration or hides a real change.
--
-- The procedure is therefore RELATIVE, not absolute:
--   1. Run C0 immediately before applying Migration C. Record its single output
--      row verbatim — that row IS the expectation for this run.
--   2. Apply the migration.
--   3. Run C-LAST (identical query) and diff it against the C0 row.
--
-- Gate on these two columns — they MUST be byte-identical:
--     cover_image_url_md5
--     image_url_storage_path_md5
--   A difference means an image URL or storage path moved. STOP and roll back.
--
-- Informational, NOT a gate:
--     cars_n, car_images_n, public_cars_n, cars_status_md5
--   These can legitimately change between the two captures if a real user edit,
--   a status sync, or the nightly cron lands in between. Investigate a
--   difference, but do not treat it as automatic failure.
--
-- Fixtures — re-verify these still exist before running, do not assume:
--   :admin_uuid  a profiles.id with role='admin'
--   :sales_uuid  a profiles.id with role='sales'
--   :car_uuid    any public.cars.id that has at least one non-deleted
--                transactions row (needed by C12)
-- Helper:
--   SELECT id, username, role FROM public.profiles WHERE role IN ('admin','sales') ORDER BY role, id;
--   SELECT t.car_id, count(*) FROM public.transactions t
--    WHERE t.deleted_at IS NULL AND t.car_id IS NOT NULL
--    GROUP BY 1 ORDER BY 2 DESC LIMIT 1;
-- ============================================================================


-- ── C0 / C-LAST. Immutability capture (pure SELECT) ─────────────────────────
-- Run VERBATIM before the migration and again after. Diff the two rows.
SELECT now() AT TIME ZONE 'Asia/Bangkok' AS captured_at_th,
       (SELECT count(*) FROM public.cars)               AS cars_n,
       (SELECT count(*) FROM public.car_images)         AS car_images_n,
       (SELECT count(*) FROM public.car_status_history) AS car_status_history_n,
       (SELECT count(*) FROM public.public_cars)        AS public_cars_n,
       (SELECT md5(string_agg(coalesce(cover_image_url,''),'|' ORDER BY id::text))
          FROM public.cars)                             AS cover_image_url_md5,
       (SELECT md5(string_agg(coalesce(image_url,'')||'#'||coalesce(storage_path,''),'|' ORDER BY id::text))
          FROM public.car_images)                       AS image_url_storage_path_md5,
       (SELECT md5(string_agg(status||':'||id::text,'|' ORDER BY id::text))
          FROM public.cars)                             AS cars_status_md5;

-- Policy fingerprint before/after. Before: exactly 3 rows, all "umhome auth full"
-- FOR ALL TO {authenticated} USING true WITH CHECK true.
-- After: exactly 10 rows and NO policy named 'umhome auth full' —
--   cars               4 (SELECT / INSERT / UPDATE / DELETE)
--   car_images         4 (SELECT / INSERT / UPDATE / DELETE)
--   car_status_history 2 (SELECT / INSERT only — append-only by design)
SELECT c.relname AS tbl, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced,
       p.polname,
       CASE p.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
                     WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE'
                     WHEN '*' THEN 'ALL' END AS cmd,
       (SELECT array_agg(rolname ORDER BY rolname) FROM pg_roles WHERE oid = ANY(p.polroles)) AS roles,
       pg_get_expr(p.polqual, p.polrelid)      AS using_expr,
       pg_get_expr(p.polwithcheck, p.polrelid) AS withcheck_expr
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE n.nspname = 'public'
  AND c.relname IN ('cars','car_images','car_status_history')
ORDER BY c.relname, cmd;


-- ============================================================================
-- SALES IS READ-ONLY
-- ============================================================================

-- ── C1. sales SELECT cars → must SUCCEED ────────────────────────────────────
-- The requirement that rules out a blanket admin-only policy: listCars() and
-- getCar() in umhome-summary-web read public.cars directly as `authenticated`.
-- EXPECT: count equals cars_n from C0; the single-row lookup returns 1 row.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT count(*) AS sales_visible_cars FROM public.cars;
  SELECT id, status FROM public.cars WHERE id = ':car_uuid'::uuid;
ROLLBACK;

-- ── C2. sales SELECT car_images → must SUCCEED ──────────────────────────────
-- getCar() selects '*, images:car_images(*)'; the embedded read must work.
-- EXPECT: count equals car_images_n from C0.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT count(*) AS sales_visible_images FROM public.car_images;
  SELECT count(*) FROM public.car_images WHERE car_id = ':car_uuid'::uuid;
ROLLBACK;

-- ── C2b. sales SELECT car_status_history → must SUCCEED ─────────────────────
-- The timeline view is reachable by sales (cs-timeline is not in SALES_BLOCKED).
-- EXPECT: count equals car_status_history_n from C0.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT count(*) FROM public.car_status_history;
ROLLBACK;

-- ── C3. sales INSERT cars → must FAIL ───────────────────────────────────────
-- EXPECT: ERROR 42501 new row violates row-level security policy for table "cars"
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  INSERT INTO public.cars (brand, model, status) VALUES ('TEST','RLS','available');
ROLLBACK;

-- ── C4. sales UPDATE cars → must FAIL ───────────────────────────────────────
-- A status change and a data edit; both must be filtered out by USING.
-- EXPECT: rows_updated_must_be_zero = 0 in both.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH u AS (
    UPDATE public.cars SET status = 'sold' WHERE id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_zero FROM u;
  WITH u2 AS (
    UPDATE public.cars SET price = price WHERE id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_zero FROM u2;
ROLLBACK;

-- ── C5. sales DELETE cars → must FAIL ───────────────────────────────────────
-- EXPECT: rows_deleted_must_be_zero = 0
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH d AS (
    DELETE FROM public.cars WHERE id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_zero FROM d;
ROLLBACK;

-- ── C6. sales INSERT / UPDATE / DELETE car_images → must FAIL ───────────────
-- NOTE: this INSERT writes a throwaway example.invalid URL inside a rolled-back
-- transaction and is expected to be REJECTED. No real image_url, storage_path
-- or R2 object is touched by any test in this file.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  INSERT INTO public.car_images (car_id, image_url)
  VALUES (':car_uuid'::uuid, 'https://example.invalid/x.jpg');
ROLLBACK;   -- EXPECT 42501 RLS violation

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH u AS (
    UPDATE public.car_images SET sort_order = sort_order
     WHERE car_id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_zero FROM u;
ROLLBACK;

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH d AS (
    DELETE FROM public.car_images WHERE car_id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_zero FROM d;
ROLLBACK;

-- ── C6b. sales INSERT / UPDATE / DELETE car_status_history → must FAIL ──────
-- Stops a sales user forging, rewriting or erasing status history even though
-- they cannot move the car.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  INSERT INTO public.car_status_history (car_id, old_status, new_status, note)
  VALUES (':car_uuid'::uuid, 'available', 'sold', 'forged');
ROLLBACK;   -- EXPECT 42501 RLS violation

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH u AS (
    UPDATE public.car_status_history SET note = 'tampered' RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_zero FROM u;
ROLLBACK;

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  WITH d AS (
    DELETE FROM public.car_status_history RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_zero FROM d;
ROLLBACK;

-- ── C7. sales calls data-writing RPCs → must FAIL ───────────────────────────
-- SCOPE NOTE: um_set_car_status_atomic / um_delete_car_images_atomic /
-- um_reorder_car_images_atomic DO NOT EXIST in this database (verified: no
-- match in pg_proc, any schema). src/api/cars.js catches PGRST202 via
-- isMissingRpc() and falls back to direct table DML — which is exactly why RLS
-- fully governs car writes and there is no SECURITY DEFINER bypass to design
-- around. Calling them would return "function does not exist", not a permission
-- result, so the writing RPCs that DO exist are tested instead.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT public.um_fix_missing_covers();
ROLLBACK;   -- EXPECT 'admin only' (the function's own um_is_admin() guard)

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT * FROM public.um_sync_all_car_sales_statuses();
ROLLBACK;   -- EXPECT 42501 permission denied for function (Migration B)

BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":sales_uuid","role":"authenticated"}';
  SELECT * FROM public.um_admin_sync_all_car_sales_statuses();
ROLLBACK;   -- EXPECT 42501 'permission denied: admin only' (Migration D)


-- ============================================================================
-- ADMIN KEEPS FULL CRUD
-- ============================================================================

-- ── C8. admin INSERT / UPDATE / DELETE cars → must SUCCEED ──────────────────
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';

  INSERT INTO public.cars (brand, model, status)
  VALUES ('TEST','RLS ADMIN','available') RETURNING id, brand;      -- EXPECT 1 row

  WITH u AS (
    UPDATE public.cars SET model = 'RLS ADMIN 2' WHERE brand = 'TEST' RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_1 FROM u;

  WITH d AS (
    DELETE FROM public.cars WHERE brand = 'TEST' RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_1 FROM d;
ROLLBACK;

-- ── C9. admin INSERT / UPDATE / DELETE car_images → must SUCCEED ────────────
-- Operates only on a scratch car created inside this transaction, so no real
-- car_images row — and therefore no real image_url or storage_path — is touched.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';

  CREATE TEMP TABLE _t ON COMMIT DROP AS
  SELECT id FROM (
    INSERT INTO public.cars (brand, model, status)
    VALUES ('TESTIMG','RLS','available') RETURNING id
  ) s;

  INSERT INTO public.car_images (car_id, image_url)
  SELECT id, 'https://example.invalid/test.jpg' FROM _t;            -- EXPECT ok

  WITH u AS (
    UPDATE public.car_images SET sort_order = 1
     WHERE car_id IN (SELECT id FROM _t) RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_1 FROM u;

  WITH d AS (
    DELETE FROM public.car_images WHERE car_id IN (SELECT id FROM _t) RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_1 FROM d;

  DELETE FROM public.cars WHERE id IN (SELECT id FROM _t);
ROLLBACK;

-- ── C9b. admin INSERT car_status_history → must SUCCEED ─────────────────────
-- setCarStatus() writes this table alongside the cars UPDATE.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  INSERT INTO public.car_status_history (car_id, old_status, new_status, note)
  VALUES (':car_uuid'::uuid, 'available', 'booked', 'migration C test');
ROLLBACK;   -- EXPECT 1 row inserted, no error

-- ── C9c. admin UPDATE car_status_history → must FAIL ────────────────────────
-- Append-only: there is no UPDATE policy, so this is denied even for an admin.
-- EXPECT: rows_updated_must_be_zero = 0
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  WITH u AS (
    UPDATE public.car_status_history SET note = 'admin tamper' RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_zero FROM u;
ROLLBACK;

-- ── C9d. admin DELETE car_status_history → must FAIL ────────────────────────
-- Append-only: there is no DELETE policy, so this is denied even for an admin.
-- EXPECT: rows_deleted_must_be_zero = 0
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  WITH d AS (
    DELETE FROM public.car_status_history RETURNING 1
  ) SELECT count(*) AS rows_deleted_must_be_zero FROM d;
ROLLBACK;

-- ── C9e. admin setCarStatus() fallback, end to end → must SUCCEED ───────────
-- Reproduces exactly what src/api/cars.js does when the atomic RPC is missing
-- (which it is): UPDATE cars, then INSERT the history row. Both must pass for
-- an admin, in one transaction, as the real code does.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';

  WITH u AS (
    UPDATE public.cars SET status = status WHERE id = ':car_uuid'::uuid RETURNING status
  ) SELECT count(*) AS cars_rows_updated_must_be_1 FROM u;

  INSERT INTO public.car_status_history (car_id, old_status, new_status, note)
  SELECT ':car_uuid'::uuid, c.status, c.status, 'setCarStatus fallback test'
  FROM public.cars c WHERE c.id = ':car_uuid'::uuid;

  SELECT count(*) AS history_rows_for_car
  FROM public.car_status_history WHERE car_id = ':car_uuid'::uuid;
ROLLBACK;

-- ── C16. hard delete a car that has history → must SUCCEED and CASCADE ──────
-- Proves the missing DELETE policy does not break hardDeleteCar(). The FK
--   car_status_history_car_id_fkey ... ON DELETE CASCADE
-- is executed by the system as a referential action, not as the invoking user,
-- so it is not filtered by RLS.
-- Uses a scratch car created inside the transaction — no real car is deleted.
-- EXPECT: history_before >= 1, car deleted, history_after = 0.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';

  CREATE TEMP TABLE _hc ON COMMIT DROP AS
  SELECT id FROM (
    INSERT INTO public.cars (brand, model, status)
    VALUES ('TESTHIST','CASCADE','available') RETURNING id
  ) s;

  INSERT INTO public.car_status_history (car_id, old_status, new_status, note)
  SELECT id, 'available', 'booked', 'cascade test' FROM _hc;

  SELECT count(*) AS history_before
  FROM public.car_status_history WHERE car_id IN (SELECT id FROM _hc);

  WITH d AS (
    DELETE FROM public.cars WHERE id IN (SELECT id FROM _hc) RETURNING 1
  ) SELECT count(*) AS car_rows_deleted_must_be_1 FROM d;

  SELECT count(*) AS history_after_must_be_zero
  FROM public.car_status_history WHERE car_id IN (SELECT id FROM _hc);
ROLLBACK;


-- ============================================================================
-- EVERYTHING ELSE MUST KEEP WORKING
-- ============================================================================

-- ── C10. anon reads public_cars → must SUCCEED, count unchanged ─────────────
-- public_cars is owned by postgres with reloptions = NULL (security_invoker not
-- set), so it runs with owner privileges and bypasses RLS on cars entirely.
-- EXPECT: equals public_cars_n from C0.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT count(*) AS anon_public_cars FROM public.public_cars;
ROLLBACK;

-- ── C11. anon direct access to cars / car_images → must stay denied ─────────
-- Already denied before the migration (no anon policy exists). Guards against
-- accidentally loosening anything.
-- EXPECT: 0 for both.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT count(*) AS anon_cars_must_be_zero        FROM public.cars;
  SELECT count(*) AS anon_car_images_must_be_zero  FROM public.car_images;
ROLLBACK;

-- ── C12. transaction trigger sync → must SUCCEED ────────────────────────────
-- Run as a SALES identity on purpose. That user may write transactions
-- ("umhome auth full" on transactions is unchanged) but can no longer UPDATE
-- public.cars. The AFTER trigger fires um_sync_transaction_car_statuses()
-- -> um_sync_one_car_sales_status() -> um_car_sales_events(), all SECURITY
-- DEFINER owned by postgres, which must still write cars.
-- Running this as postgres would prove nothing — that mistake was made and
-- corrected during Migration B.
-- EXPECT: no error, no RLS violation.
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

-- ── C13. service_role paths → must SUCCEED ──────────────────────────────────
-- service_role has rolbypassrls; the auto-delete-sold-cars edge function and
-- the nightly cron depend on this.
BEGIN;
  SET LOCAL ROLE service_role;
  SELECT count(*) FROM public.cars;
  WITH u AS (
    UPDATE public.cars SET updated_at = updated_at WHERE id = ':car_uuid'::uuid RETURNING 1
  ) SELECT count(*) AS rows_updated_must_be_1 FROM u;
ROLLBACK;

-- ── C14. um_fix_missing_covers as ADMIN → must SUCCEED ──────────────────────
-- SECURITY DEFINER owned by postgres: must still write cars/car_images despite
-- the new admin-only policies. Inside ROLLBACK — it writes cover_image_url.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  SELECT public.um_fix_missing_covers();     -- EXPECT jsonb {"fixed_count": N}
ROLLBACK;

-- ── C15. admin Data Health wrapper → must SUCCEED ───────────────────────────
-- Migration D shipped to production; it reaches cars through the definer chain.
-- Regression guard.
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":":admin_uuid","role":"authenticated"}';
  SELECT * FROM public.um_admin_sync_all_car_sales_statuses();
ROLLBACK;


-- ── C-LAST. Rerun both C0 queries. ──────────────────────────────────────────
-- cover_image_url_md5 and image_url_storage_path_md5 must be byte-identical to
-- the C0 row recorded at the start of THIS run. Policy query must now return 12
-- rows with no 'umhome auth full' remaining.
