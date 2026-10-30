-- =====================================================================
-- FRCS INVENTORY · 03 權限
--
-- 表和 view 對前端完全不可見（deny-all），唯一入口是 frcs_* function。
-- anon key 外流也沒關係：沒有 frcs_staff 的帳號什麼都做不了。
-- 要在 01、02 之後執行。可重複執行。
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'frcs_staff','frcs_stores','frcs_config','frcs_items','frcs_stock_moves','frcs_members',
    'frcs_txns','frcs_sales','frcs_preorders','frcs_purchases','frcs_expenses','frcs_topay',
    'frcs_returns','frcs_transfers','frcs_day_close','frcs_vendors']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

revoke all on frcs_v_stock from anon, authenticated;

-- 只開放 RPC，且只給登入者
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'frcs\_%'
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- 內部輔助函式連 authenticated 都不用直接呼叫
revoke execute on function frcs_require_staff() from authenticated;
revoke execute on function frcs_require_owner() from authenticated;
-- frcs_is_staff 要留給 authenticated：04 的 Storage policy 會用到
revoke execute on function frcs_is_owner()      from authenticated;
revoke execute on function frcs_store_of(text)  from authenticated;
revoke execute on function frcs_qty(text, text) from authenticated;
revoke execute on function frcs_d(text)         from authenticated;

-- ---------------------------------------------------------------------
-- 建立第一個帳號：Dashboard → Authentication → Users → Add user，
-- 再把 email 換掉執行：
-- ---------------------------------------------------------------------
-- insert into frcs_staff (user_id, name, role)
-- select id, 'Francis', 'owner' from auth.users where email = 'you@example.com'
-- on conflict (user_id) do update set role = 'owner', active = true;
