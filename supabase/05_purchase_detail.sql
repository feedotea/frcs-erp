-- =====================================================================
-- FRCS INVENTORY · 05 採購單細節：廠商主檔、備註、物流單號、可刪除
-- 給 2026-10-24 已部署的庫用；全新安裝跑 01~04 就已包含。可重複執行。
-- 含 delete 會跳「Potential issue」視窗，要按 Run query。
-- =====================================================================
alter table frcs_purchases add column if not exists note text;
alter table frcs_purchases add column if not exists tracking text;

create table if not exists frcs_vendors (
  name       text primary key,                    -- 廠商名（例如 Seoul / 東大門 A）
  contact    text,                                -- 聯絡人
  phone      text,                                -- 電話 / LINE / 微信
  currency   text not null default 'TWD',
  rate       numeric not null default 1,          -- 預設匯率，開單時帶入
  lead_days  int,                                 -- 下單到到貨大約幾天
  note       text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table frcs_vendors enable row level security;
alter table frcs_vendors force row level security;
revoke all on frcs_vendors from anon, authenticated;

-- ---------------------------------------------------------------------
-- 開 App 一次撈完
-- ---------------------------------------------------------------------
create or replace function frcs_load(p_store text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_store text;
  v_owner boolean;
  v_today date := frcs_today();
  v_from  date := (date_trunc('month', frcs_today()) - interval '12 month')::date;
begin
  perform frcs_require_staff();
  v_store := frcs_store_of(p_store);
  v_owner := frcs_is_owner();

  return jsonb_build_object(
    'today',  v_today,
    'store',  v_store,
    'stores', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name) order by sort_order, code), '[]'::jsonb)
               from frcs_stores where active),
    'me',     (select jsonb_build_object('name', name, 'role', role) from frcs_staff where user_id = auth.uid()),

    'items',  (select coalesce(jsonb_agg(jsonb_build_object(
                 'no', i.no, 'styleNo', i.style_no, 'size', i.size, 'color', i.color,
                 'name', i.name, 'cat', i.cat, 'gender', i.gender,
                 'cost', case when v_owner then i.cost else 0 end,
                 'price', i.price, 'low', i.low, 'photo', i.photo, 'note', i.note, 'active', i.active,
                 'qty', coalesce((select s.qty from frcs_v_stock s where s.store = v_store and s.no = i.no), 0),
                 'elsewhere', coalesce((select jsonb_agg(jsonb_build_object('store', s.store, 'qty', s.qty))
                                        from frcs_v_stock s where s.no = i.no and s.store <> v_store and s.qty > 0), '[]'::jsonb)
               ) order by i.created_at desc, i.style_no, i.color, i.size, i.no), '[]'::jsonb)
               from frcs_items i),

    'members', (select coalesce(jsonb_agg(jsonb_build_object(
                  'phone', phone, 'name', name, 'tier', tier, 'disc', disc, 'spent', spent, 'joined', joined, 'note', note
                ) order by spent desc), '[]'::jsonb) from frcs_members),

    -- 今日交易
    'txns',   (select coalesce(jsonb_agg(jsonb_build_object(
                 'no', t.no, 'date', t.sold_on, 'time', t.at_time, 'total', t.total, 'pay', t.pay, 'member', t.member,
                 'memberPhone', t.member_phone, 'voided', t.voided, 'voidReason', t.void_reason,
                 'items', case when v_owner then t.items
                               else (select coalesce(jsonb_agg(x - 'cost' || '{"cost":0}'::jsonb), '[]'::jsonb)
                                     from jsonb_array_elements(t.items) x) end
               ) order by t.created_at desc), '[]'::jsonb)
               from frcs_txns t where t.store = v_store and t.sold_on = v_today),

    -- 銷售明細（近 12 個月；報表、動銷、退貨選單用）
    'sales',  (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', s.id, 'date', s.sold_on, 'sku', s.sku, 'qty', s.qty, 'amt', s.amt,
                 'cost', case when v_owner then s.cost else 0 end, 'note', s.note, 'txn', s.txn_no
               ) order by s.sold_on, s.created_at), '[]'::jsonb)
               from frcs_sales s where s.store = v_store and s.sold_on >= v_from),

    -- 預購：未完成的全部 ＋ 完成 60 天內的
    'preorders', (select coalesce(jsonb_agg(jsonb_build_object(
                    'no', p.no, 'sku', p.sku, 'qty', p.qty, 'price', p.price, 'deposit', p.deposit,
                    'stage', p.stage, 'cust', p.cust, 'memberPhone', p.member_phone, 'createdAt', p.created_on
                  ) order by p.created_at desc), '[]'::jsonb)
                  from frcs_preorders p
                  where p.store = v_store and (p.stage <> '已收尾款' or p.done_on >= v_today - 60)),

    -- 入庫紀錄（動銷分析要用首次／最後入庫日，所以全部給）
    'intakeLog', (select coalesce(jsonb_agg(jsonb_build_object(
                    'date', m.occurred_on, 'time', m.at_time, 'no', m.no, 'name', i.name, 'qty', m.qty_delta, 'kind', m.kind
                  ) order by m.created_at desc), '[]'::jsonb)
                  from frcs_stock_moves m join frcs_items i on i.no = m.no
                  where m.store = v_store and m.kind in ('intake','receive','transfer_in')),

    'returns', (select coalesce(jsonb_agg(jsonb_build_object(
                  'time', r.at_time, 'type', r.type, 'name', r.name, 'qty', r.qty, 'amt', r.amt, 'reason', r.reason
                ) order by r.created_at desc), '[]'::jsonb)
                from frcs_returns r where r.store = v_store and r.ret_on = v_today),

    -- 今天有沒有日結過
    'dayClose', (select jsonb_build_object('closedOn', c.closed_on, 'byPay', c.by_pay, 'txnCount', c.txn_count,
                   'cashExpected', c.cash_expected, 'cashCounted', c.cash_counted, 'diff', c.diff, 'note', c.note)
                 from frcs_day_close c where c.store = v_store and c.closed_on = v_today),

    'transfers', (select coalesce(jsonb_agg(jsonb_build_object(
                    'from', t.from_store, 'to', t.to_store, 'sku', t.sku, 'name', t.name, 'qty', t.qty, 'date', t.moved_on, 'note', t.note
                  ) order by t.created_at desc), '[]'::jsonb)
                  from frcs_transfers t where (t.from_store = v_store or t.to_store = v_store) and t.moved_on >= v_today - 90),

    -- 以下只有老闆拿得到
    'purchases', case when v_owner then
                  (select coalesce(jsonb_agg(jsonb_build_object(
                     'no', p.no, 'vendor', p.vendor, 'currency', p.currency, 'rate', p.rate,
                     'freight', p.freight, 'duty', p.duty, 'stage', p.stage, 'ordered', p.ordered_on, 'eta', p.eta,
                     'items', p.items, 'note', p.note, 'tracking', p.tracking, 'receivedAt', p.received_on
                   ) order by p.created_at desc), '[]'::jsonb)
                   from frcs_purchases p where p.store = v_store)
                 else '[]'::jsonb end,
    'vendors',  case when v_owner then
                  (select coalesce(jsonb_agg(jsonb_build_object(
                     'name', v.name, 'contact', v.contact, 'phone', v.phone, 'currency', v.currency,
                     'rate', v.rate, 'leadDays', v.lead_days, 'note', v.note, 'active', v.active
                   ) order by v.name), '[]'::jsonb)
                   from frcs_vendors v where v.active)
                 else '[]'::jsonb end,
    'expenses', case when v_owner then
                  (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', e.id, 'date', e.spent_on, 'cat', e.cat, 'amt', e.amt, 'who', e.who, 'note', e.note
                   ) order by e.spent_on, e.created_at), '[]'::jsonb)
                   from frcs_expenses e where e.store = v_store and e.spent_on >= v_from)
                 else '[]'::jsonb end,
    'topay',    case when v_owner then
                  (select coalesce(jsonb_agg(jsonb_build_object(
                     'no', t.no, 'who', t.who, 'amt', t.amt, 'cat', t.cat
                   ) order by t.created_at), '[]'::jsonb)
                   from frcs_topay t where t.store = v_store and not t.paid)
                 else '[]'::jsonb end
  );
end $$;

-- ---------------------------------------------------------------------
-- 採購（老闆）
-- ---------------------------------------------------------------------
create or replace function frcs_upsert_purchase(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_store text := frcs_store_of(p_store);
  v_no    text := p->>'no';
begin
  perform frcs_require_owner();
  if v_no is null or v_no = '' then
    raise exception '缺採購單號' using errcode = '22023';
  end if;
  if exists (select 1 from frcs_purchases where no = v_no and stage = '已入倉') then
    raise exception '已入倉的採購單不能再改' using errcode = '22023';
  end if;
  insert into frcs_purchases (no, store, vendor, currency, rate, freight, duty, stage, ordered_on, eta, items, note, tracking)
  values (v_no, v_store, nullif(p->>'vendor', ''), coalesce(nullif(p->>'currency', ''), 'TWD'),
          coalesce((p->>'rate')::numeric, 1), coalesce((p->>'freight')::numeric, 0), coalesce((p->>'duty')::numeric, 0),
          coalesce(nullif(p->>'stage', ''), '已訂購'), nullif(p->>'ordered', ''), nullif(p->>'eta', ''),
          coalesce(p->'items', '[]'::jsonb), nullif(p->>'note', ''), nullif(p->>'tracking', ''))
  on conflict (no) do update set
    vendor = excluded.vendor, currency = excluded.currency, rate = excluded.rate,
    freight = excluded.freight, duty = excluded.duty, stage = excluded.stage,
    ordered_on = excluded.ordered_on, eta = excluded.eta, items = excluded.items,
    note = excluded.note, tracking = excluded.tracking, updated_at = now();
  return jsonb_build_object('ok', true, 'no', v_no);
end $$;

-- 刪採購單（老闆）；已入倉的不能刪，庫存和成本已經寫進去了
create or replace function frcs_delete_purchase(p_no text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_stage text;
begin
  perform frcs_require_owner();
  select stage into v_stage from frcs_purchases where no = p_no;
  if v_stage is null then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;
  if v_stage = '已入倉' then
    raise exception '已入倉的採購單不能刪，請用盤點或退貨調整' using errcode = '22023';
  end if;
  delete from frcs_topay where no = 'TP-' || p_no and not paid;
  delete from frcs_purchases where no = p_no;
  return jsonb_build_object('ok', true);
end $$;

-- 廠商主檔（老闆）
create or replace function frcs_upsert_vendor(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text := trim(p->>'name');
begin
  perform frcs_require_owner();
  if v_name is null or v_name = '' then
    raise exception '廠商名稱不能空白' using errcode = '22023';
  end if;
  insert into frcs_vendors (name, contact, phone, currency, rate, lead_days, note, active)
  values (v_name, nullif(p->>'contact', ''), nullif(p->>'phone', ''), coalesce(nullif(p->>'currency', ''), 'TWD'),
          coalesce((p->>'rate')::numeric, 1), (p->>'leadDays')::int, nullif(p->>'note', ''), true)
  on conflict (name) do update set
    contact = excluded.contact, phone = excluded.phone, currency = excluded.currency, rate = excluded.rate,
    lead_days = excluded.lead_days, note = excluded.note, active = true;
  return jsonb_build_object('ok', true, 'name', v_name);
end $$;

-- 刪廠商 = 停用（採購單上的廠商名還在）
create or replace function frcs_delete_vendor(p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform frcs_require_owner();
  update frcs_vendors set active = false where name = p_name;
  return jsonb_build_object('ok', true);
end $$;

-- 新函式要收權限
do $$
declare f text;
begin
  foreach f in array array['frcs_delete_purchase(text)','frcs_upsert_vendor(jsonb)','frcs_delete_vendor(text)'] loop
    execute 'revoke all on function '||f||' from public, anon';
    execute 'grant execute on function '||f||' to authenticated';
  end loop;
end $$;

select proname from pg_proc where proname in ('frcs_load','frcs_upsert_purchase','frcs_delete_purchase','frcs_upsert_vendor','frcs_delete_vendor') order by 1;
