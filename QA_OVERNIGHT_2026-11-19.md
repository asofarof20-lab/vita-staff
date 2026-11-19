# VITANET overnight QA — 2026-11-19

## Safety boundary
- This work is isolated to GitHub branch `test/overnight-qa-2026-11-19`.
- No commits were made to `main`.
- No production database schema, rows, policies, functions, or Edge Functions were changed.
- Supabase production project was inspected read-only.
- An isolated Supabase development branch is still pending explicit cost approval.

## Verified environment
- Repository: `asofarof20-lab/vita-staff`
- Current application entry: `index.html`
- Supabase project status: `ACTIVE_HEALTHY`
- Current deployed Edge Functions observed: `vita-staff-login` (v1), `vita-catalog-orders` (v5), `create-vita-user` (v11).
- Database migration history includes staff roles, accountant cash access, archive guards, financial audit, catalog warehouse, catalog orders, stock movements/returns, GPS/workday and stock feed migrations.

## Confirmed blocker: missing PostgREST SELECT grants
The current `index.html` reads catalog order items, warehouse stock and return receipts directly through `db.from(...).select(...)`.
The live database has RLS enabled and read policies for these tables, but the `authenticated` role currently has no table-level SELECT privilege on:
- `public.vita_order_items`
- `public.vita_stock`
- `public.vita_stock_movements`
- `public.vita_stock_return_receipts`

A row-level policy cannot grant a table privilege. The UI can therefore fail before RLS filtering is evaluated. The proposed QA-only migration `database/migrations/20261119_staff_read_grants_for_catalog_stock.sql` grants SELECT only to `authenticated`; existing RLS policies remain responsible for row access. It does not grant write access or direct anonymous access to warehouse tables.

## Permission logic observed
- Shop finance table: authenticated clients have SELECT/INSERT, but no direct UPDATE/DELETE; financial operations use guarded RPCs.
- Shop and staff tables: no authenticated DELETE privilege; shop blacklist and employee deactivation are used instead of physical deletion.
- Accountant RPCs exist for registering shop payments, receiving cash from staff, transferring/depositing cash and related finance operations.
- Confirmed gap: the current accountant UI blocks debt adjustments, and the current `vita_record_shop_adjustment_by_staff` RPC permits only admin/delivery. The QA branch now updates the UI and proposes a guarded RPC version that also permits accountant, with a mandatory reason and active-shop check.
- Catalog order shop assignment allows admin/accountant; catalog order confirmation is admin-only; delivery assignment is admin-only.
- Return-to-warehouse RPC permits admin/accountant/delivery and checks order status, product code and cumulative return quantity.
- Delivery request completion RPC checks that the caller is an active delivery employee and that the request belongs to them.

These are static policy/function observations, not successful end-to-end role tests.

## Security and performance items requiring QA
- Supabase security advisor reports 34 SECURITY DEFINER functions executable by authenticated users. Each must be reviewed for an internal role/ownership check; the advisor finding alone does not prove exploitability.
- Leaked-password protection is disabled in Auth settings.
- Performance advisor reports multiple permissive RLS policies on several public tables and three duplicate indexes.
- Additional no-primary-key / no-policy findings occur in the legacy backup schema; verify schema exposure and grants before any cleanup. No backup data was modified.

## Confirmed warehouse safety issue
The existing live UI offered a one-click initializer that added 1,000 units of every catalog product as explicitly fictional starting stock. That is unsafe for real inventory. The QA branch removes that button and its handler, and the QA migration revokes direct execution of the legacy bulk initializer. Initial quantities must be entered from physically verified counts using normal receipt/adjustment workflows with reasons.

## Required isolated test cases
1. Admin: login, employee creation/edit/archive guards, shop blacklist/restore, all-store finance/report views.
2. Accountant: all-store requests and totals, catalog order visibility/items, shop assignment, payments, cash receipt from agent/delivery, staff-to-staff transfer, office deposit, audit visibility.
3. Delivery: only own assigned requests/orders; record collection/payment/return; cannot read another delivery worker's requests.
4. Sales: only assigned-zone/assigned-shop workflows; cannot alter shop debt/financial amounts.
5. Warehouse: receipt, adjustment with reason, confirmation-based stock decrement, physical return receipt increment, movement/audit history.
6. Catalog integration: public order submission validation/rate limiting, catalog price verification, order item persistence, store assignment, confirmation, delivery assignment and completion.
7. Regression: no physical shop/staff deletion; archive blocked by cash balance, open requests, unconfirmed collections, outstanding shop debt or active route assignments.
8. Mobile UI: login, navigation, forms, table/card readability, map/GPS permissions, printing and offline/error states.

## Changes saved on the isolated GitHub QA branch
- Updated the accountant finance form so the accountant can submit shop debt adjustments.
- Added a guarded SQL RPC definition allowing admin, delivery and accountant to adjust debt, requiring a reason and an active shop.
- Added SELECT grants needed by the staff UI to read order items and warehouse/return tables; existing RLS policies continue to control rows.
- Removed the UI action that created 1,000 fictional units for every catalog product and proposed revoking the legacy bulk-seed RPC.
- Verified the changed files by fetching them back from GitHub. Branch comparison reports 5 commits ahead of `main`, 0 behind; `main`'s `index.html` SHA remains unchanged.
- No CI checks are configured/reported for the latest commit. The SQL migration has not been applied and no end-to-end runtime test has been run because an isolated Supabase branch is pending cost approval.

## Release gate
Do not merge this branch, deploy a new frontend, apply migrations to production, deploy Edge Functions, or switch staff until isolated database tests pass and the user explicitly approves release.
