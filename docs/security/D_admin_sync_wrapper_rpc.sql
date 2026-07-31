-- ============================================================================
-- Migration D — admin-only wrapper for the Data Health sync
-- Project : jvvjwblwdeggetnpfvgq
-- Status  : DRAFT — DO NOT EXECUTE WITHOUT APPROVAL
-- Scope   : creates ONE new function. Does not touch the existing
--           um_sync_all_car_sales_statuses() — neither its body nor its ACL.
--           No data, no policies, no R2, no image columns, no edge functions.
-- ============================================================================
-- REGRESSION BEING FIXED (confirmed):
--   Migration B revoked EXECUTE on public.um_sync_all_car_sales_statuses()
--   from PUBLIC, anon and authenticated. Live ACL is now exactly:
--       postgres=X/postgres | service_role=X/postgres
--   But umhome-summary-web still calls that RPC from the browser as
--   `authenticated`:
--       src/features/dataHealth.js:280  syncHealthStatuses()
--         await supabase.rpc('um_sync_all_car_sales_statuses')
--   reached via the admin-only Data Health action 'health-sync-status'.
--   Result today: an ADMIN clicking that button gets
--       42501 permission denied for function um_sync_all_car_sales_statuses
--   Sales is unaffected — 'health-sync-status' is in SALES_BLOCKED and the
--   'health' tab is not in SALES_TABS.
--
-- WHY A WRAPPER AND NOT A RE-GRANT:
--   Re-granting `authenticated` on the original function would restore an
--   unguarded, RLS-bypassing, cars-writing entry point — the vulnerability
--   Migration B closed. The wrapper adds the missing authorization check
--   instead, and the internal function stays closed to authenticated.
--
-- HOW THE PRIVILEGE CHAIN WORKS:
--   The wrapper is SECURITY DEFINER owned by postgres. Inside it, the call to
--   um_sync_all_car_sales_statuses() has its EXECUTE checked against the
--   DEFINER (postgres), not the caller — so the inner function does not need
--   to be granted to authenticated for this to work.
--
-- search_path: pinned to 'public', with pg_temp LAST so a caller cannot
--   shadow an object with a temp table (standard SECURITY DEFINER hardening).
--
-- RETURN SIGNATURE — VERIFIED AGAINST THE LIVE DATABASE, NOT ASSUMED.
--   Queried read-only 2026-07-31:
--     pg_get_function_result(oid) =
--       TABLE(total_cars integer, sold integer, approved integer,
--             booked integer, available integer)
--     proretset = true, prorettype = record, pronargs = 0, language = plpgsql
--   Per-column, from unnest(proallargtypes, proargnames, proargmodes):
--     1 total_cars integer  (mode t)
--     2 sold       integer  (mode t)
--     3 approved   integer  (mode t)
--     4 booked     integer  (mode t)
--     5 available  integer  (mode t)
--   The wrapper's RETURNS TABLE below mirrors this exactly — same five columns,
--   same names, same integer types, same order. If the internal function's
--   signature is ever changed, this wrapper must be changed in lockstep or the
--   `return query select *` will fail with a structure mismatch.
--
-- WHY service_role IS NOT GRANTED ON THE WRAPPER:
--   The wrapper exists solely as the browser/admin entry point. service_role
--   already holds EXECUTE on the internal um_sync_all_car_sales_statuses()
--   (ACL after Migration B: postgres=X/postgres | service_role=X/postgres) and
--   calls it directly, so granting the wrapper would add a second path to the
--   same operation for no benefit. Note also that is_admin() resolves via
--   auth.uid(), which is NULL for a service_role request — so a service_role
--   caller would be REJECTED by the wrapper's own guard anyway.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.um_admin_sync_all_car_sales_statuses()
RETURNS TABLE(total_cars integer, sold integer, approved integer, booked integer, available integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  -- Authorization gate. is_admin() is STABLE SECURITY DEFINER and checks
  -- profiles.role = 'admin' for auth.uid(). For anon, auth.uid() is NULL, so
  -- this is false and the call is rejected.
  if not public.is_admin() then
    raise exception
      'permission denied: admin only'
      using errcode = '42501';
  end if;

  return query select * from public.um_sync_all_car_sales_statuses();
end;
$function$;

COMMENT ON FUNCTION public.um_admin_sync_all_car_sales_statuses() IS
  'Admin-only wrapper around um_sync_all_car_sales_statuses(). Exists so the Data Health "sync statuses" button works for admins without re-granting authenticated EXECUTE on the unguarded internal function (see Migration B).';

-- Strip every inherited grant before granting back only what is wanted.
--
-- IMPORTANT — why service_role must be revoked explicitly:
--   This project has ALTER DEFAULT PRIVILEGES in place. pg_default_acl shows,
--   for grantor=postgres, schema=public, objtype='f':
--     postgres=X/postgres | anon=X/postgres | authenticated=X/postgres
--     | service_role=X/postgres
--   So a newly CREATEd function in public is born with EXECUTE already granted
--   to anon, authenticated AND service_role. "Not granting" a role is NOT the
--   same as that role having no privilege. The first version of this migration
--   revoked only PUBLIC and anon, which left service_role holding EXECUTE and
--   failed the ACL assertion (test D5).
--   Treat this as the standard pattern for every new function in this project:
--   REVOKE from all four, then GRANT only the intended roles.
REVOKE ALL ON FUNCTION public.um_admin_sync_all_car_sales_statuses()
  FROM PUBLIC, anon, authenticated, service_role;

-- authenticated may CALL it; non-admins are rejected inside by is_admin().
-- service_role is deliberately NOT granted — see the header note.
GRANT EXECUTE ON FUNCTION public.um_admin_sync_all_car_sales_statuses()
  TO authenticated;

COMMIT;

-- Resulting ACL for the wrapper (verified live 2026-07-31):
--   postgres=X/postgres | authenticated=X/postgres
--   (postgres is the owner and keeps EXECUTE implicitly; PUBLIC, anon and
--    service_role all have none.)
--
-- The internal um_sync_all_car_sales_statuses() ACL is UNTOUCHED by this
-- migration and remains exactly as Migration B left it:
--   postgres=X/postgres | service_role=X/postgres
-- authenticated is NOT granted back on the internal function.
