-- This legacy RPC is not used by the current app. It lets a sales user
-- create a cash-collection movement without a shop payment/collection record,
-- so remove direct API execution and keep cash balances source-linked.
REVOKE ALL ON FUNCTION public.vita_record_staff_cash_collection(numeric,text)
  FROM PUBLIC, anon, authenticated;
