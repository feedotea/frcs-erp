-- =====================================================================
-- FRCS INVENTORY · 06 商品加「廠商」欄（原備註改成廠商；採購入倉自動帶入）
-- 給已部署的庫用；全新安裝 01~04 已含。可重複執行。
-- =====================================================================
alter table frcs_items add column if not exists vendor text;

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
                 'price', i.price, 'low', i.low, 'photo', i.photo, 'vendor', i.vendor, 'note', i.note, 'active', i.active,
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
-- 款式整組存檔（新增／編輯商品的主要入口）
-- p_style: {styleNo, name, cat, gender, price, cost?, photo?, note, low}
-- p_skus:  [{no, size, color, qty?}]   qty 只在 SKU 是新的時候當初始庫存
--   · 同款每個 SKU 共用 name/cat/gender/price/cost/photo/note/low
--   · 這次沒列進來的舊 SKU → 下架（庫存紀錄都在）
--   · 店員：可建新款、改品名分類圖片；售價只有新款可填，舊款的售價和進價只有老闆改得動
-- ---------------------------------------------------------------------
create or replace function frcs_save_style(p_style jsonb, p_skus jsonb, p_store text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid      uuid := frcs_require_staff();
  v_store  text := frcs_store_of(p_store);
  v_owner  boolean := frcs_is_owner();
  v_sn     text := trim(p_style->>'styleNo');
  v_exists boolean;
  v_price  numeric;
  v_cost   numeric;
  v_photo  text;
  r        jsonb;
  v_no     text;
  v_new    boolean;
  v_qty    int;
  v_kept   text[] := '{}';
  n_new    int := 0;
  n_upd    int := 0;
begin
  if v_sn is null or v_sn = '' then
    raise exception '款式編號不能空白' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_skus, '[]'::jsonb)) = 0 then
    raise exception '至少要有一個 SKU' using errcode = '22023';
  end if;
  v_exists := exists (select 1 from frcs_items where style_no = v_sn);

  -- 售價／進價：老闆照送來的；店員只有新款可以填售價，進價一律不收
  select price, cost, photo into v_price, v_cost, v_photo from frcs_items where style_no = v_sn limit 1;
  if v_owner or not v_exists then
    v_price := coalesce((p_style->>'price')::numeric, v_price, 0);
  end if;
  if v_owner and p_style ? 'cost' then
    v_cost := coalesce((p_style->>'cost')::numeric, 0);
  end if;
  v_cost := coalesce(v_cost, 0);
  if p_style ? 'photo' then v_photo := nullif(p_style->>'photo', ''); end if;

  for r in select * from jsonb_array_elements(p_skus) loop
    v_no := trim(r->>'no');
    if v_no is null or v_no = '' then continue; end if;
    -- 這個條碼若已屬於別的款式，擋掉
    if exists (select 1 from frcs_items where no = v_no and style_no <> v_sn) then
      raise exception '條碼 % 已經是別的款式在用', v_no using errcode = '22023';
    end if;
    v_new := not exists (select 1 from frcs_items where no = v_no);
    insert into frcs_items (no, style_no, size, color, name, cat, gender, cost, price, low, photo, vendor, note, active)
    values (v_no, v_sn, nullif(trim(r->>'size'), ''), nullif(trim(r->>'color'), ''),
            coalesce(nullif(trim(p_style->>'name'), ''), '未命名'),
            coalesce(nullif(p_style->>'cat', ''), '上衣'), coalesce(nullif(p_style->>'gender', ''), '男'),
            v_cost, v_price, coalesce((p_style->>'low')::int, 1), v_photo,
            nullif(trim(p_style->>'vendor'), ''), nullif(p_style->>'note', ''), true)
    on conflict (no) do update set
      style_no = excluded.style_no, size = excluded.size, color = excluded.color,
      name = excluded.name, cat = excluded.cat, gender = excluded.gender,
      cost = excluded.cost, price = excluded.price, low = excluded.low,
      photo = excluded.photo, note = excluded.note, active = true, updated_at = now(),
      -- 沒帶 vendor 這個 key 就保留原值
      vendor = case when p_style ? 'vendor' then excluded.vendor else frcs_items.vendor end;
    v_kept := v_kept || v_no;
    if v_new then n_new := n_new + 1; else n_upd := n_upd + 1; end if;

    v_qty := coalesce((r->>'qty')::int, 0);
    if v_new and v_qty > 0 then
      insert into frcs_stock_moves (id, store, no, kind, qty_delta, occurred_on, at_time, note, created_by)
      values (md5('init:' || v_no || ':' || v_store)::uuid, v_store, v_no, 'intake', v_qty, frcs_today(),
              to_char(now() at time zone 'Asia/Taipei', 'HH24:MI'), '建檔初始庫存', uid)
      on conflict (id) do nothing;
    end if;
  end loop;

  -- 沒列進來的舊 SKU 下架
  update frcs_items set active = false, updated_at = now()
  where style_no = v_sn and not (no = any(v_kept)) and active;

  return jsonb_build_object('ok', true, 'styleNo', v_sn, 'created', n_new, 'updated', n_upd);
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
      update frcs_items set cost = v_cost, active = true, updated_at = now(),
             vendor = coalesce(vendor, po.vendor)
       where no = it->>'no';
      v_upd := v_upd + 1;
    else
      insert into frcs_items (no, style_no, size, color, name, cat, gender, cost, price, low, vendor)
      values (it->>'no', coalesce(nullif(it->>'styleNo', ''), it->>'no'), nullif(it->>'size', ''), nullif(it->>'color', ''),
              coalesce(nullif(it->>'name', ''), '未命名'), coalesce(nullif(it->>'cat', ''), '上衣'),
              coalesce(nullif(it->>'gender', ''), '男'), v_cost,
              case when coalesce((it->>'price')::numeric, 0) > 0 then (it->>'price')::numeric
                   else round(v_cost * 2.8 / 10) * 10 end, 1, po.vendor);
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

select column_name from information_schema.columns where table_name='frcs_items' and column_name='vendor';
