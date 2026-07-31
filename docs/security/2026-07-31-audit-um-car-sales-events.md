# READ-ONLY audit — `public.um_car_sales_events(uuid)`

- **Project:** `jvvjwblwdeggetnpfvgq`
- **Date:** 2026-07-31
- **Type:** read-only audit. No SQL was executed other than `SELECT`; nothing was
  changed, and no remediation has been applied.
- **Verdict:** 🟡 **Confirmed unauthenticated information disclosure of internal
  business data. No PII confirmed in the returned columns.** Severity is a
  judgement call for the owner — see §9.

---

## 1. Function properties

| Property | Value |
|---|---|
| Signature | `public.um_car_sales_events(p_car_id uuid)` |
| Security | **`SECURITY DEFINER`** |
| Owner | **`postgres`** (has `rolbypassrls = true`) |
| `search_path` | `search_path=public` — pinned, so no search_path hijack |
| Volatility | `STABLE` (reads only, writes nothing) |
| Language | `sql` |

## 2. Privileges

ACL: `=X/postgres | postgres=X/postgres | anon=X/postgres | authenticated=X/postgres | service_role=X/postgres`

| Grantee | EXECUTE |
|---|---|
| `PUBLIC` (`=X`) | ✅ yes |
| `anon` | ✅ **yes** |
| `authenticated` | ✅ yes |
| `service_role` | ✅ yes |
| `postgres` (owner) | ✅ yes |

This is the `pg_default_acl` pattern documented in the Migration D notes — the
function was created and never had those inherited grants stripped.

## 3. Guards

**None.** The body is a single `SELECT … UNION ALL SELECT …`. It contains no
`auth.uid()`, no `is_admin()`, no `um_is_admin()`, no role check, and no
filtering tied to the caller's identity. The only inputs are `p_car_id` and
row-level data conditions.

## 4. Full function body

```sql
CREATE OR REPLACE FUNCTION public.um_car_sales_events(p_car_id uuid)
 RETURNS TABLE(transaction_id text, event_date date, event_created_at timestamp with time zone, event_status text, event_priority integer, event_side text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- ฝั่งหลัก: จอง / อนุมัติ / ปล่อย / คืนจอง / รถใหม่ของเปลี่ยนคัน
  select
    t.id::text,
    t.date,
    t.created_at,
    case t.type
      when 'delivered' then 'sold'
      when 'approved'  then 'approved'
      when 'booking'   then 'booked'
      when 'cancelled' then 'available'
      when 'swap'      then 'booked'
      else null
    end as event_status,
    case t.type
      when 'delivered' then 4
      when 'cancelled' then 3
      when 'approved'  then 2
      when 'booking'   then 1
      when 'swap'      then 1
      else 0
    end as event_priority,
    case when t.type = 'swap' then 'new' else 'main' end as event_side
  from public.transactions t
  join public.cars c on c.id = p_car_id
  where t.deleted_at is null
    and t.car_id = p_car_id
    and t.match_status in ('manual','matched_v10','matched_v11','matched_v12')
    and t.type in ('booking','approved','delivered','cancelled','swap')
    and (
      t.match_status = 'manual'
      or t.date is null
      or t.date >= (c.created_at at time zone 'Asia/Bangkok')::date
    )

  union all

  -- ฝั่งรถคันเดิมของเปลี่ยนคัน: กลับเป็นพร้อมขาย
  select
    t.id::text,
    t.date,
    t.created_at,
    'available'::text,
    3,
    'old'::text
  from public.transactions t
  join public.cars c on c.id = p_car_id
  where t.deleted_at is null
    and t.type = 'swap'
    and t.old_car_id = p_car_id
    and t.old_match_status in ('manual','matched_v10','matched_v11','matched_v12')
    and (
      t.old_match_status = 'manual'
      or t.date is null
      or t.date >= (c.created_at at time zone 'Asia/Bangkok')::date
    );
$function$
```

## 5. Tables read and columns returned

**Reads:** `public.transactions` (primary), `public.cars` (joined only to obtain
`created_at` for the date cutoff — no `cars` column is returned).

**Returns 6 columns:**

| Column | Type | Source |
|---|---|---|
| `transaction_id` | text | `transactions.id` |
| `event_date` | date | `transactions.date` |
| `event_created_at` | timestamptz | `transactions.created_at` |
| `event_status` | text | derived from `transactions.type` |
| `event_priority` | integer | derived from `transactions.type` |
| `event_side` | text | derived (`main` / `new` / `old`) |

## 6. What `anon` actually sees — tested

Called as `anon` inside a rolled-back transaction against a real car id:

```sql
BEGIN; SET LOCAL ROLE anon;
SELECT * FROM public.um_car_sales_events('b86b3eec-…-a910f98e9641'::uuid)
ORDER BY event_date DESC NULLS LAST LIMIT 8;
ROLLBACK;
```

Returned 8 rows, e.g.:

| transaction_id | event_date | event_created_at | event_status | event_priority | event_side |
|---|---|---|---|---|---|
| `txn_1785039429376_f6ckvh` | 2026-07-25 | 2026-07-26 04:17:27+00 | sold | 4 | main |
| `txn_1784377829137_jh6xs2` | 2026-07-18 | 2026-07-18 12:30:42+00 | approved | 2 | main |
| `txn_1783860201205_445bui` | 2026-07-12 | 2026-07-12 12:43:44+00 | booked | 1 | main |
| `txn_1782273007326_tvdreb` | 2026-06-23 | 2026-06-24 03:50:12+00 | booked | 1 | main |
| … | … | … | … | … | … |

For contrast, the same `anon` session reading the table directly:

```sql
BEGIN; SET LOCAL ROLE anon;
SELECT count(*) FROM public.transactions;   -- returns 0
ROLLBACK;
```

`transactions` has RLS enabled with a single policy `umhome auth full`
(`FOR ALL TO authenticated`), so `anon` is correctly denied direct access.
**The function is the only path by which `anon` obtains this data, and it does
so by bypassing that RLS.**

### The attack is practical, not theoretical

`p_car_id` does not have to be guessed. The public showroom view
`public.public_cars` — readable by `anon` and used by `index.html` — exposes an
`id` column (full column list: `id, license_plate, brand, model, sub_model,
year, price, original_price, is_hot, mileage, engine, gear, description,
created_at, images, cover_image_url, color_group, color_name`). Anyone can
enumerate every listed car's id from the public site and then call this function
for each one, using the publishable key embedded in `index.html`.

## 7. Callers

| Caller | Type | Notes |
|---|---|---|
| `public.um_sync_one_car_sales_status(uuid)` | `SECURITY DEFINER`, owner `postgres` | Calls it twice to derive car status |
| `public.um_sync_all_car_sales_statuses()` | `SECURITY DEFINER`, owner `postgres` | Calls it in the loop's `EXISTS` filter |

Verified by scanning `pg_proc.prosrc` across the whole database — those two are
the only references.

**No caller outside the database:**

- `umhomecar/umhomecar-showroom` (`index.html`, `admin.html`,
  `showroom-color-addon.js`) — no match
- `umhomecar/umhome-summary-web` (`src/`, `api/`, `cloudflare/`, `supabase/`) —
  no match
- `cron.job` — the only job is `auto-delete-sold-cars-daily`, which does not
  call it
- Edge functions — `auto-delete-sold-cars`, `admin-create-user`,
  `admin-reset-password`; none call it

Both internal callers are `SECURITY DEFINER` owned by `postgres`, so their
`EXECUTE` is checked against the definer. **The `PUBLIC` / `anon` /
`authenticated` grants are not required by any caller.**

## 8. PII assessment

The `transactions` table does contain sensitive fields:
`plate`, `old_plate`, `model`, `old_model`, `branch`, `bank`, `seller`,
`source`.

**None of them are returned by this function.** The `SELECT` list projects only
the six columns in §5. The disclosure is therefore limited to:

- internal transaction identifiers (`txn_<epoch>_<random>`)
- the dates and creation timestamps of booking / approval / delivery /
  cancellation events
- the derived status and ordering of those events

**No customer name, phone, bank, branch, salesperson, or licence plate is
exposed through this function.** On the evidence gathered, this is **not** a PII
leak.

What *is* disclosed is commercially sensitive internal business data: for any
publicly listed car, an unauthenticated party can reconstruct its full sales
timeline — how many times it was booked, whether bookings were cancelled and
when, when it was approved, and when it was delivered. The public showroom
exposes a car's *current* state, not this history.

## 9. Verdict

🟡 **Confirmed: unauthenticated, RLS-bypassing read access to internal
transaction history. Needs hardening. Not confirmed as a PII leak.**

What is proven, with direct evidence:

1. `anon` holds `EXECUTE` (ACL + `has_function_privilege` both confirm)
2. The body contains no authorization guard of any kind
3. `SECURITY DEFINER` + owner `postgres` (`rolbypassrls`) bypasses the
   `transactions` RLS policy
4. `anon` reading `transactions` directly returns 0 rows, but through this
   function returns full event history — tested, not inferred
5. Car ids are enumerable from the public `public_cars` view
6. No caller anywhere requires the `anon` / `authenticated` / `PUBLIC` grants

What is **not** claimed:

- No PII is exposed through the returned columns (§8)
- Business impact is not quantified here — how damaging a competitor knowing
  the booking/cancellation history of each car is, is the owner's call, not
  something this audit can determine

## 10. Suggested remediation (NOT applied, not approved)

Same shape as Migration B, and expected to be non-breaking because no external
caller exists:

```sql
REVOKE ALL ON FUNCTION public.um_car_sales_events(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
```

Retaining `postgres` (owner) alone is sufficient for both internal callers,
since they are `SECURITY DEFINER` owned by `postgres`. Whether to keep
`service_role` is a separate decision; there is no current `service_role`
caller.

This has **not** been drafted as a migration or executed. It is recorded here
only so the finding carries a concrete next step.
