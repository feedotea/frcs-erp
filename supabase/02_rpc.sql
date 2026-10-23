-- =====================================================================
-- FRCS INVENTORY · 02 RPC
--
-- 前端只碰這裡的 function，不直接 select / insert 任何表。
--   · 每支開頭先 frcs_require_staff() 或 frcs_require_owner()
--   · 寫入吃前端給的 id，on conflict do nothing → 離線重送不會變兩筆
--   · 成本、開銷、採購、待匯款只回給 owner；店員帳號連資料都拿不到
-- 貼進 SQL Editor 前：LC_ALL=en_US.UTF-8 pbcopy < supabase/02_rpc.sql
-- =====================================================================

-- 小工具：前端送來的字串日期 → date，壞掉或空白就用今天
create or replace function frcs_d(p text) returns date
language plpgsql immutable as $$
begin
  if p is null or p = '' then return null; end if;
  return p::date;
exception when others then
  return null;
end $$;

-- 店別：沒給就用員工預設，再沒有就第一間店
create or replace function frcs_store_of(p_store text) returns text
language plpgsql stable security definer set search_path = public as $$
declare s text;
begin
  s := nullif(p_store, '');
  if s is null then
    select store into s from frcs_staff where user_id = auth.uid();
  end if;
  if s is null then
    select code into s from frcs_stores where active order by sort_order, code limit 1;
  end if;
  if not exists (select 1 from frcs_stores where code = s and active) then
    raise exception '店別不存在：%', s using errcode = '22023';
  end if;
  return s;
end $$;

-- 商品目前庫存（某店）
create or replace function frcs_qty(p_store text, p_no text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(qty_delta), 0)::int from frcs_stock_moves where store = p_store and no = p_no;
$$;

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
                 'no', i.no, 'name', i.name, 'cat', i.cat, 'gender', i.gender,
                 'cost', case when v_owner then i.cost else 0 end,
                 'price', i.price, 'low', i.low, 'photo', i.photo, 'note', i.note, 'active', i.active,
                 'qty', coalesce((select s.qty from frcs_v_stock s where s.store = v_store and s.no = i.no), 0),
                 'elsewhere', coalesce((select jsonb_agg(jsonb_build_object('store', s.store, 'qty', s.qty))
                                        from frcs_v_stock s where s.no = i.no and s.store <> v_store and s.qty > 0), '[]'::jsonb)
               ) order by i.created_at desc, i.no), '[]'::jsonb)
               from frcs_items i),

    'members', (select coalesce(jsonb_agg(jsonb_build_object(
                  'phone', phone, 'name', name, 'tier', tier, 'disc', disc, 'spent', spent, 'joined', joined, 'note', note
                ) order by spent desc), '[]'::jsonb) from frcs_members),

    -- 今日交易
    'txns',   (select coalesce(jsonb_agg(jsonb_build_object(
                 'no', t.no, 'date', t.sold_on, 'time', t.at_time, 'total', t.total, 'pay', t.pay, 'member', t.member,
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
                    'stage', p.stage, 'cust', p.cust, 'createdAt', p.created_on
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

    'transfers', (select coalesce(jsonb_agg(jsonb_build_object(
                    'from', t.from_store, 'to', t.to_store, 'sku', t.sku, 'name', t.name, 'qty', t.qty, 'date', t.moved_on, 'note', t.note
                  ) order by t.created_at desc), '[]'::jsonb)
                  from frcs_transfers t where (t.from_store = v_store or t.to_store = v_store) and t.moved_on >= v_today - 90),

    -- 以下只有老闆拿得到
    'purchases', case when v_owner then
                  (select coalesce(jsonb_agg(jsonb_build_object(
                     'no', p.no, 'vendor', p.vendor, 'currency', p.currency, 'rate', p.rate,
                     'freight', p.freight, 'duty', p.duty, 'stage', p.stage, 'ordered', p.ordered_on, 'eta', p.eta,
                     'items', p.items, 'receivedAt', p.received_on
                   ) order by p.created_at desc), '[]'::jsonb)
                   from frcs_purchases p where p.store = v_store)
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
-- 老闆模式 PIN（PIN 本身不送到前端）
-- ---------------------------------------------------------------------
create or replace function frcs_check_pin(p_pin text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  perform frcs_require_owner();
  return exists (select 1 from frcs_config where key = 'pin' and value = p_pin);
end $$;

create or replace function frcs_set_pin(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform frcs_require_owner();
  if p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN 要 4 到 6 位數字' using errcode = '22023';
  end if;
  insert into frcs_config (key, value) values ('pin', p_pin)
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 商品主檔
-- p_item: {no, name, cat, gender, cost, price, low, photo, note, qty?}
--   · 店員可以建、改品名／售價／分類／圖片；進價只有老闆改得動（帶了也當沒帶）
--   · 新建時帶 qty > 0 → 寫一筆 intake 作初始庫存
-- ---------------------------------------------------------------------
create or replace function frcs_upsert_item(p_item jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_owner boolean := frcs_is_owner();
  v_no    text := trim(p_item->>'no');
  v_new   boolean;
  v_qty   int := coalesce((p_item->>'qty')::int, 0);
begin
  if v_no is null or v_no = '' then
    raise exception '商品編號不能空白' using errcode = '22023';
  end if;
  v_new := not exists (select 1 from frcs_items where no = v_no);

  insert into frcs_items (no, name, cat, gender, cost, price, low, photo, note, active)
  values (
    v_no,
    coalesce(nullif(trim(p_item->>'name'), ''), '未命名'),
    coalesce(nullif(p_item->>'cat', ''), '上衣'),
    coalesce(nullif(p_item->>'gender', ''), '男'),
    case when v_owner then coalesce((p_item->>'cost')::numeric, 0) else 0 end,
    coalesce((p_item->>'price')::numeric, 0),
    coalesce((p_item->>'low')::int, 1),
    nullif(p_item->>'photo', ''),
    nullif(p_item->>'note', ''),
    coalesce((p_item->>'active')::boolean, true)
  )
  on conflict (no) do update set
    name   = excluded.name,
    cat    = excluded.cat,
    gender = excluded.gender,
    price  = excluded.price,
    low    = excluded.low,
    note   = excluded.note,
    active = excluded.active,
    -- 沒帶 photo 這個 key 就保留原圖；帶空字串 = 刪圖
    photo  = case when p_item ? 'photo' then excluded.photo else frcs_items.photo end,
    cost   = case when v_owner and p_item ? 'cost' then excluded.cost else frcs_items.cost end,
    updated_at = now();

  if v_new and v_qty > 0 then
    insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, note, created_by)
    values (md5('init:' || v_no || ':' || v_store)::uuid, v_store, v_no, 'intake', v_qty, frcs_today(),
            to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'), '建檔初始庫存', uid)
    on conflict (id) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'no', v_no, 'new', v_new, 'qty', frcs_qty(v_store, v_no));
end $$;

-- CSV 匯入：整批 upsert，qty 視為「盤點後的數字」寫成調整
create or replace function frcs_bulk_upsert_items(p_items jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_owner();
  v_store text := frcs_store_of(p_store);
  r       jsonb;
  v_no    text;
  v_added int := 0;
  v_upd   int := 0;
  v_cur   int;
  v_want  int;
begin
  for r in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_no := trim(r->>'no');
    if v_no is null or v_no = '' then continue; end if;
    if exists (select 1 from frcs_items where no = v_no) then v_upd := v_upd + 1; else v_added := v_added + 1; end if;

    insert into frcs_items (no, name, cat, gender, cost, price, low)
    values (v_no, coalesce(nullif(trim(r->>'name'), ''), '未命名'),
            coalesce(nullif(r->>'cat', ''), '上衣'), coalesce(nullif(r->>'gender', ''), '男'),
            coalesce((r->>'cost')::numeric, 0), coalesce((r->>'price')::numeric, 0), coalesce((r->>'low')::int, 1))
    on conflict (no) do update set
      name = excluded.name, cat = excluded.cat, gender = excluded.gender,
      cost = excluded.cost, price = excluded.price, low = excluded.low, active = true, updated_at = now();

    if r ? 'qty' then
      v_want := coalesce((r->>'qty')::int, 0);
      v_cur  := frcs_qty(v_store, v_no);
      if v_want <> v_cur then
        insert into frcs_stock_moves (store, no, kind, qty_delta, note, created_by)
        values (v_store, v_no, 'count', v_want - v_cur, 'CSV 匯入調整', uid);
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'added', v_added, 'updated', v_upd);
end $$;

-- 上架／下架
create or replace function frcs_set_item_active(p_no text, p_active boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform frcs_require_owner();
  update frcs_items set active = p_active, updated_at = now() where no = p_no;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 會員
-- ---------------------------------------------------------------------
create or replace function frcs_upsert_member(p_member jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_phone text := regexp_replace(coalesce(p_member->>'phone', ''), '\D', '', 'g');
begin
  perform frcs_require_staff();
  if length(v_phone) < 8 then
    raise exception '電話格式不對' using errcode = '22023';
  end if;
  insert into frcs_members (phone, name, tier, disc, spent, joined, note)
  values (v_phone, coalesce(nullif(trim(p_member->>'name'), ''), '會員'),
          coalesce(nullif(p_member->>'tier', ''), '一般'),
          coalesce((p_member->>'disc')::numeric, 0.95),
          coalesce((p_member->>'spent')::numeric, 0),
          coalesce(nullif(p_member->>'joined', ''), to_char(frcs_today(), 'YYYY.MM')),
          nullif(p_member->>'note', ''))
  on conflict (phone) do update set
    name = excluded.name, tier = excluded.tier, disc = excluded.disc, note = excluded.note;
  return jsonb_build_object('ok', true, 'phone', v_phone);
end $$;

-- ---------------------------------------------------------------------
-- 結帳
-- p_txn: {no, date, time, total, pay, member, memberPhone, items:[{no,name,price,qty}]}
-- 單號重複 = 重送，整筆略過
-- ---------------------------------------------------------------------
create or replace function frcs_checkout(p_txn jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_no    text := p_txn->>'no';
  v_date  date := coalesce(frcs_d(p_txn->>'date'), frcs_today());
  v_time  text := coalesce(p_txn->>'time', to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'));
  v_items jsonb := '[]'::jsonb;
  it      jsonb;
  v_cost  numeric;
  v_qty   int;
  v_phone text;
begin
  if v_no is null or v_no = '' then
    raise exception '缺交易單號' using errcode = '22023';
  end if;
  if exists (select 1 from frcs_txns where no = v_no) then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;

  -- 成本用後端主檔的數字，不信前端
  for it in select * from jsonb_array_elements(coalesce(p_txn->'items', '[]'::jsonb)) loop
    select cost into v_cost from frcs_items where no = it->>'no';
    v_items := v_items || jsonb_build_object(
      'no', it->>'no', 'name', it->>'name', 'price', coalesce((it->>'price')::numeric, 0),
      'qty', coalesce((it->>'qty')::int, 1), 'cost', coalesce(v_cost, 0));
  end loop;

  v_phone := nullif(regexp_replace(coalesce(p_txn->>'memberPhone', ''), '\D', '', 'g'), '');

  insert into frcs_txns (no, store, sold_on, at_time, total, pay, member, member_phone, items, created_by)
  values (v_no, v_store, v_date, v_time, coalesce((p_txn->>'total')::numeric, 0), p_txn->>'pay',
          nullif(p_txn->>'member', ''), v_phone, v_items, uid);

  for it in select * from jsonb_array_elements(v_items) loop
    v_qty := (it->>'qty')::int;
    insert into frcs_sales (id, store, sold_on, sku, qty, amt, cost, txn_no)
    values (md5('sale:' || v_no || ':' || (it->>'no'))::uuid, v_store, v_date, it->>'no', v_qty,
            (it->>'price')::numeric * v_qty, (it->>'cost')::numeric * v_qty, v_no)
    on conflict (id) do nothing;
    insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, ref, created_by)
    values (md5('mv:' || v_no || ':' || (it->>'no'))::uuid, v_store, it->>'no', 'sale', -v_qty, v_date, v_time, v_no, uid)
    on conflict (id) do nothing;
  end loop;

  if v_phone is not null then
    update frcs_members set spent = spent + coalesce((p_txn->>'total')::numeric, 0) where phone = v_phone;
  end if;

  return jsonb_build_object('ok', true, 'no', v_no);
end $$;

-- 手動補記銷售 p_sale: {id, date, sku, qty, amt, note}
create or replace function frcs_manual_sale(p_sale jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_id    uuid := coalesce((p_sale->>'id')::uuid, gen_random_uuid());
  v_qty   int  := coalesce((p_sale->>'qty')::int, 1);
  v_cost  numeric;
  v_date  date := coalesce(frcs_d(p_sale->>'date'), frcs_today());
begin
  select cost into v_cost from frcs_items where no = p_sale->>'sku';
  if v_cost is null then
    raise exception '查無商品 %', p_sale->>'sku' using errcode = '22023';
  end if;
  insert into frcs_sales (id, store, sold_on, sku, qty, amt, cost, note)
  values (v_id, v_store, v_date, p_sale->>'sku', v_qty, coalesce((p_sale->>'amt')::numeric, 0), v_cost * v_qty,
          coalesce(p_sale->>'note', '補記'))
  on conflict (id) do nothing;
  insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, note, created_by)
  values (md5('manual:' || v_id::text)::uuid, v_store, p_sale->>'sku', 'manual', -v_qty, v_date, '補記銷售', uid)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- 入庫 p: {id, sku, qty, date, time}
create or replace function frcs_intake(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_id    uuid := coalesce((p->>'id')::uuid, gen_random_uuid());
begin
  if coalesce((p->>'qty')::int, 0) <= 0 then
    raise exception '數量要大於 0' using errcode = '22023';
  end if;
  insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, created_by)
  values (v_id, v_store, p->>'sku', 'intake', (p->>'qty')::int, coalesce(frcs_d(p->>'date'), frcs_today()),
          coalesce(p->>'time', to_char(now() at time zone 'Asia/Taipei', 'HH24:MI')), uid)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'qty', frcs_qty(v_store, p->>'sku'));
end $$;

-- 盤點 p_counts: [{no, qty}]，寫差額，不覆蓋
create or replace function frcs_stocktake(p_counts jsonb, p_store text default null, p_date text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_date  date := coalesce(frcs_d(p_date), frcs_today());
  r       jsonb;
  v_cur   int;
  v_want  int;
  n       int := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_counts, '[]'::jsonb)) loop
    v_want := coalesce((r->>'qty')::int, 0);
    v_cur  := frcs_qty(v_store, r->>'no');
    if v_want <> v_cur then
      insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, note, created_by)
      values (coalesce((r->>'id')::uuid, gen_random_uuid()), v_store, r->>'no', 'count', v_want - v_cur, v_date,
              '盤點 帳面 ' || v_cur || ' → 實際 ' || v_want, uid)
      on conflict (id) do nothing;
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'adjusted', n);
end $$;

-- 退換貨 p: {id, sku, qty, type, name, amt, reason, date, time}
create or replace function frcs_return(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_staff();
  v_store text := frcs_store_of(p_store);
  v_id    uuid := coalesce((p->>'id')::uuid, gen_random_uuid());
  v_qty   int  := coalesce((p->>'qty')::int, 1);
  v_date  date := coalesce(frcs_d(p->>'date'), frcs_today());
  v_time  text := coalesce(p->>'time', to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'));
  v_type  text := coalesce(nullif(p->>'type', ''), '退貨');
  v_cost  numeric;
  v_name  text;
begin
  select cost, name into v_cost, v_name from frcs_items where no = p->>'sku';
  insert into frcs_returns (id, store, ret_on, at_time, sku, name, qty, amt, cost, type, reason)
  values (v_id, v_store, v_date, v_time, p->>'sku', coalesce(v_name, p->>'name'), v_qty,
          coalesce((p->>'amt')::numeric, 0), coalesce(v_cost, 0) * v_qty, v_type, nullif(p->>'reason', ''))
  on conflict (id) do nothing;
  -- 退貨、換貨都回補庫存
  insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, note, created_by)
  values (md5('ret:' || v_id::text)::uuid, v_store, p->>'sku', 'return', v_qty, v_date, v_time, v_type, uid)
  on conflict (id) do nothing;
  -- 只有退貨沖銷營收
  if v_type = '退貨' then
    insert into frcs_sales (id, store, sold_on, sku, qty, amt, cost, note)
    values (md5('retsale:' || v_id::text)::uuid, v_store, v_date, p->>'sku', -v_qty,
            -coalesce((p->>'amt')::numeric, 0), -coalesce(v_cost, 0) * v_qty, '退貨')
    on conflict (id) do nothing;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 調貨 p: {id, fromStore, toStore, sku, qty, date, note}
create or replace function frcs_transfer(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := frcs_require_staff();
  v_id   uuid := coalesce((p->>'id')::uuid, gen_random_uuid());
  v_from text := p->>'fromStore';
  v_to   text := p->>'toStore';
  v_qty  int  := coalesce((p->>'qty')::int, 0);
  v_date date := coalesce(frcs_d(p->>'date'), frcs_today());
  v_name text;
begin
  if v_from = v_to or v_qty <= 0 then
    raise exception '調貨資料不對' using errcode = '22023';
  end if;
  if (select count(*) from frcs_stores where code in (v_from, v_to) and active) <> 2 then
    raise exception '店別不存在' using errcode = '22023';
  end if;
  if exists (select 1 from frcs_transfers where id = v_id) then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;
  if frcs_qty(v_from, p->>'sku') < v_qty then
    raise exception '% 庫存不足', v_from using errcode = '22023';
  end if;
  select name into v_name from frcs_items where no = p->>'sku';
  insert into frcs_transfers (id, from_store, to_store, sku, name, qty, moved_on, note)
  values (v_id, v_from, v_to, p->>'sku', v_name, v_qty, v_date, nullif(p->>'note', ''));
  insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, note, ref, created_by)
  values (md5('tout:' || v_id::text)::uuid, v_from, p->>'sku', 'transfer_out', -v_qty, v_date, '調往 ' || v_to, v_id::text, uid),
         (md5('tin:'  || v_id::text)::uuid, v_to,   p->>'sku', 'transfer_in',   v_qty, v_date, '來自 ' || v_from, v_id::text, uid)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 預購
-- 建單 p: {no, sku, qty, price, deposit, cust, createdAt}；訂金 > 0 就同時記一筆營收
-- ---------------------------------------------------------------------
create or replace function frcs_upsert_preorder(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_store text := frcs_store_of(p_store);
  v_no    text := p->>'no';
  v_dep   numeric := coalesce((p->>'deposit')::numeric, 0);
  v_date  date := coalesce(frcs_d(p->>'createdAt'), frcs_today());
  v_new   boolean;
begin
  perform frcs_require_staff();
  if v_no is null or v_no = '' then
    raise exception '缺預購單號' using errcode = '22023';
  end if;
  v_new := not exists (select 1 from frcs_preorders where no = v_no);
  insert into frcs_preorders (no, store, sku, qty, price, deposit, stage, cust, created_on)
  values (v_no, v_store, p->>'sku', coalesce((p->>'qty')::int, 1), coalesce((p->>'price')::numeric, 0), v_dep,
          coalesce(nullif(p->>'stage', ''), '收訂金'), nullif(p->>'cust', ''), v_date)
  on conflict (no) do update set
    sku = excluded.sku, qty = excluded.qty, price = excluded.price, deposit = excluded.deposit,
    cust = excluded.cust, updated_at = now();
  if v_new and v_dep > 0 then
    insert into frcs_sales (id, store, sold_on, sku, qty, amt, cost, note)
    values (md5('dep:' || v_no)::uuid, v_store, v_date, p->>'sku', 0, v_dep, 0, '訂金 ' || v_no)
    on conflict (id) do nothing;
  end if;
  return jsonb_build_object('ok', true, 'no', v_no);
end $$;

-- 推進階段；到「已收尾款」= 客人取貨：記尾款營收、扣庫存、進今日交易
create or replace function frcs_preorder_advance(p_no text, p_stage text, p_pay text default '預購尾款')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := frcs_require_staff();
  po     frcs_preorders%rowtype;
  v_bal  numeric;
  v_cost numeric;
  v_name text;
  v_time text := to_char(now() at time zone 'Asia/Taipei', 'HH24:MI');
  v_txn  text;
begin
  select * into po from frcs_preorders where no = p_no;
  if po.no is null then
    raise exception '查無預購單 %', p_no using errcode = '22023';
  end if;
  if po.stage = '已收尾款' then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;

  update frcs_preorders set stage = p_stage, updated_at = now(),
         done_on = case when p_stage = '已收尾款' then frcs_today() else done_on end
  where no = p_no;

  if p_stage = '已收尾款' then
    v_bal := po.price * po.qty - po.deposit;
    select cost, name into v_cost, v_name from frcs_items where no = po.sku;
    v_txn := 'PO' || right(po.no, 4);
    insert into frcs_sales (id, store, sold_on, sku, qty, amt, cost, note, txn_no)
    values (md5('final:' || po.no)::uuid, po.store, frcs_today(), po.sku, po.qty, v_bal, coalesce(v_cost, 0) * po.qty, '尾款 ' || po.no, v_txn)
    on conflict (id) do nothing;
    insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, note, ref, created_by)
    values (md5('pomv:' || po.no)::uuid, po.store, po.sku, 'sale', -po.qty, frcs_today(), v_time, '預購出貨', po.no, uid)
    on conflict (id) do nothing;
    insert into frcs_txns (no, store, sold_on, at_time, total, pay, member, items, created_by)
    values (v_txn, po.store, frcs_today(), v_time, v_bal, p_pay, po.cust,
            jsonb_build_array(jsonb_build_object('no', po.sku, 'name', coalesce(v_name, po.sku), 'qty', po.qty,
                                                 'price', v_bal, 'cost', coalesce(v_cost, 0))), uid)
    on conflict (no) do nothing;
  end if;
  return jsonb_build_object('ok', true, 'stage', p_stage);
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
  insert into frcs_purchases (no, store, vendor, currency, rate, freight, duty, stage, ordered_on, eta, items)
  values (v_no, v_store, nullif(p->>'vendor', ''), coalesce(nullif(p->>'currency', ''), 'TWD'),
          coalesce((p->>'rate')::numeric, 1), coalesce((p->>'freight')::numeric, 0), coalesce((p->>'duty')::numeric, 0),
          coalesce(nullif(p->>'stage', ''), '已訂購'), nullif(p->>'ordered', ''), nullif(p->>'eta', ''),
          coalesce(p->'items', '[]'::jsonb))
  on conflict (no) do update set
    vendor = excluded.vendor, currency = excluded.currency, rate = excluded.rate,
    freight = excluded.freight, duty = excluded.duty, stage = excluded.stage,
    ordered_on = excluded.ordered_on, eta = excluded.eta, items = excluded.items, updated_at = now();
  return jsonb_build_object('ok', true, 'no', v_no);
end $$;

-- 入倉：換匯＋運費關稅按件攤提算單件成本，建檔／更新成本、加庫存
create or replace function frcs_receive_purchase(p_no text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := frcs_require_owner();
  po      frcs_purchases%rowtype;
  it      jsonb;
  v_units int := 0;
  v_extra numeric;
  v_cost  numeric;
  v_qty   int;
  v_new   int := 0;
  v_upd   int := 0;
begin
  select * into po from frcs_purchases where no = p_no;
  if po.no is null then
    raise exception '查無採購單 %', p_no using errcode = '22023';
  end if;
  if po.stage = '已入倉' then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;

  select coalesce(sum((x->>'qty')::int), 0) into v_units from jsonb_array_elements(po.items) x;
  v_extra := case when v_units > 0 then (po.freight + po.duty) / v_units else 0 end;

  for it in select * from jsonb_array_elements(po.items) loop
    v_qty  := coalesce((it->>'qty')::int, 0);
    v_cost := round(coalesce((it->>'unitFx')::numeric, 0) * po.rate + v_extra);
    if exists (select 1 from frcs_items where no = it->>'no') then
      update frcs_items set cost = v_cost, active = true, updated_at = now() where no = it->>'no';
      v_upd := v_upd + 1;
    else
      insert into frcs_items (no, name, cat, gender, cost, price, low)
      values (it->>'no', coalesce(nullif(it->>'name', ''), '未命名'), coalesce(nullif(it->>'cat', ''), '上衣'),
              coalesce(nullif(it->>'gender', ''), '男'), v_cost,
              case when coalesce((it->>'price')::numeric, 0) > 0 then (it->>'price')::numeric
                   else round(v_cost * 2.8 / 10) * 10 end, 1);
      v_new := v_new + 1;
    end if;
    if v_qty > 0 then
      insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, note, ref, created_by)
      values (md5('recv:' || po.no || ':' || (it->>'no'))::uuid, po.store, it->>'no', 'receive', v_qty, frcs_today(),
              to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'), '採購入倉 ' || coalesce(po.vendor, ''), po.no, uid)
      on conflict (id) do nothing;
    end if;
  end loop;

  update frcs_purchases set stage = '已入倉', received_on = frcs_today(), updated_at = now() where no = p_no;
  return jsonb_build_object('ok', true, 'created', v_new, 'updated', v_upd);
end $$;

-- ---------------------------------------------------------------------
-- 開銷、待匯款（老闆）
-- ---------------------------------------------------------------------
create or replace function frcs_add_expense(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_store text := frcs_store_of(p_store);
begin
  perform frcs_require_owner();
  if coalesce((p->>'amt')::numeric, 0) <= 0 then
    raise exception '金額要大於 0' using errcode = '22023';
  end if;
  insert into frcs_expenses (id, store, spent_on, cat, amt, who, note)
  values (coalesce((p->>'id')::uuid, gen_random_uuid()), v_store, coalesce(frcs_d(p->>'date'), frcs_today()),
          coalesce(nullif(p->>'cat', ''), '雜支'), (p->>'amt')::numeric, nullif(p->>'who', ''), nullif(p->>'note', ''))
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function frcs_add_topay(p jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_store text := frcs_store_of(p_store);
begin
  perform frcs_require_owner();
  insert into frcs_topay (no, store, who, amt, cat)
  values (p->>'no', v_store, nullif(p->>'who', ''), coalesce((p->>'amt')::numeric, 0), nullif(p->>'cat', ''))
  on conflict (no) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- 已匯款：結清並記成開銷
create or replace function frcs_pay_topay(p_no text, p_date text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare t frcs_topay%rowtype;
begin
  perform frcs_require_owner();
  select * into t from frcs_topay where no = p_no;
  if t.no is null then
    raise exception '查無待匯款 %', p_no using errcode = '22023';
  end if;
  if t.paid then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;
  update frcs_topay set paid = true, paid_on = coalesce(frcs_d(p_date), frcs_today()) where no = p_no;
  insert into frcs_expenses (id, store, spent_on, cat, amt, who, note)
  values (md5('topay:' || p_no)::uuid, t.store, coalesce(frcs_d(p_date), frcs_today()),
          coalesce(t.cat, '進貨貨款'), t.amt, t.who, '待匯款結清 ' || p_no)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- 全店合併（本月）
create or replace function frcs_rollup()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from date := date_trunc('month', frcs_today())::date;
begin
  perform frcs_require_owner();
  return coalesce((
    select jsonb_object_agg(s.code, jsonb_build_object(
      'rev',  coalesce((select sum(amt)  from frcs_sales    where store = s.code and sold_on  >= v_from), 0),
      'cogs', coalesce((select sum(cost) from frcs_sales    where store = s.code and sold_on  >= v_from), 0),
      'exp',  coalesce((select sum(amt)  from frcs_expenses where store = s.code and spent_on >= v_from), 0)))
    from frcs_stores s where s.active
  ), '{}'::jsonb);
end $$;
