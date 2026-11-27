-- Keep delivery request and shared-agent visibility updates available to live agent panels.
alter publication supabase_realtime add table public.vita_sales_requests;
alter publication supabase_realtime add table public.vita_shop_shared_agents;
