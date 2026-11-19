-- QA cleanup: remove only indexes confirmed as exact duplicates by Supabase advisors.
-- Keep the original indexes already used by the existing application.
DROP INDEX IF EXISTS public.vita_staff_locations_latest_by_staff;
DROP INDEX IF EXISTS public.vita_staff_workdays_one_open_per_staff;
DROP INDEX IF EXISTS public.vita_order_items_order_id_idx;
