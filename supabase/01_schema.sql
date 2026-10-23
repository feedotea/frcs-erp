-- =====================================================================
-- FRCS INVENTORY · 01 資料表
--
-- 原則跟 FEEDO ERP 一樣：
--   · 前端只呼叫 frcs_* function，所有表 RLS deny-all（見 03）
--   · 庫存是流水帳：frcs_stock_moves 只增不刪，庫存 = 加總
--   · 每筆寫入帶前端產生的 id，重送不會變兩筆
-- 貼進 SQL Editor 前：LC_ALL=en_US.UTF-8 pbcopy < supabase/01_schema.sql
-- =====================================================================

create extension if not exists pgcrypto;

-- 台灣日期
create or replace function frcs_today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- ---------------------------------------------------------------------
-- 0. 員工名冊與權限
--    role：staff（店員：收銀、商品、預購）／ owner（老闆：＋成本、帳務、採購）
-- ---------------------------------------------------------------------
create table if not exists frcs_staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  role       text not null default 'staff' check (role in ('staff','owner')),
  store      text,                                -- 預設登入的店，null = 第一間
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function frcs_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from frcs_staff where user_id = auth.uid() and active);
$$;

create or replace function frcs_is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from frcs_staff where user_id = auth.uid() and active and role = 'owner');
$$;

create or replace function frcs_require_staff() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception '尚未登入' using errcode = '28000';
  end if;
  if not frcs_is_staff() then
    raise exception '此帳號沒有 FRCS 權限' using errcode = '42501';
  end if;
  return uid;
end $$;

create or replace function frcs_require_owner() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := frcs_require_staff();
begin
  if not frcs_is_owner() then
    raise exception '這個功能限老闆使用' using errcode = '42501';
  end if;
  return uid;
end $$;

-- ---------------------------------------------------------------------
-- 1. 店別、設定
-- ---------------------------------------------------------------------
create table if not exists frcs_stores (
  code       text primary key,
  name       text not null,
  sort_order int  not null default 0,
  active     boolean not null default true
);

create table if not exists frcs_config (
  key   text primary key,
  value text
);

-- ---------------------------------------------------------------------
-- 2. 商品主檔（全店共用；庫存按店分，見 stock_moves）
-- ---------------------------------------------------------------------
create table if not exists frcs_items (
  no         text primary key,                    -- SKU 編號 = 條碼（一個尺寸顏色一張）
  style_no   text not null,                       -- 款式編號；單一規格的商品 style_no = no
  size       text,                                -- S / M / L / F …，沒有就 null
  color      text,                                -- 黑 / 白 …，沒有就 null
  name       text not null,                       -- 款式名（同款每個 SKU 一樣）
  cat        text not null default '上衣',
  gender     text not null default '男',
  cost       numeric not null default 0,          -- 進價（每件，含運費關稅攤提）
  price      numeric not null default 0,          -- 售價
  low        int     not null default 1,          -- 安全量
  photo      text,                                -- Storage 公開網址
  note       text,
  active     boolean not null default true,       -- false = 下架，不出現在清單
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists frcs_items_style on frcs_items(style_no);

-- ---------------------------------------------------------------------
-- 3. 庫存流水帳
--    kind：sale / return / intake / receive / count / transfer_out / transfer_in / manual / void
-- ---------------------------------------------------------------------
create table if not exists frcs_stock_moves (
  id          uuid primary key default gen_random_uuid(),
  store       text not null references frcs_stores(code),
  no          text not null references frcs_items(no),
  kind        text not null,
  qty_delta   int  not null,
  occurred_on date not null default frcs_today(),
  at_time     text,                               -- HH:MM，給畫面用
  note        text,
  ref         text,                               -- 交易單號 / 採購單號 / 預購單號
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index if not exists frcs_stock_moves_store_no on frcs_stock_moves(store, no);
create index if not exists frcs_stock_moves_kind_on on frcs_stock_moves(kind, occurred_on);

create or replace view frcs_v_stock as
  select store, no, sum(qty_delta)::int as qty
  from frcs_stock_moves
  group by store, no;

-- ---------------------------------------------------------------------
-- 4. 會員
-- ---------------------------------------------------------------------
create table if not exists frcs_members (
  phone      text primary key,                    -- 純數字
  name       text not null default '會員',
  tier       text not null default '一般',
  disc       numeric not null default 0.95,       -- 0.95 = 95 折
  spent      numeric not null default 0,
  joined     text,                                -- '2026.03'
  note       text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. 交易（收銀一張單）＋ 銷售明細帳
--    sales 是損益用的流水帳：結帳一件一筆、訂金、尾款、補記、退貨（負數）
-- ---------------------------------------------------------------------
create table if not exists frcs_txns (
  no           text primary key,
  store        text not null references frcs_stores(code),
  sold_on      date not null default frcs_today(),
  at_time      text,
  total        numeric not null default 0,
  pay          text,
  member       text,
  member_phone text,
  items        jsonb not null default '[]'::jsonb,
  voided       boolean not null default false,    -- 作廢：銷售明細刪掉、庫存反向寫回，單留著
  void_reason  text,
  voided_at    timestamptz,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index if not exists frcs_txns_store_on on frcs_txns(store, sold_on);

create table if not exists frcs_sales (
  id         uuid primary key default gen_random_uuid(),
  store      text not null references frcs_stores(code),
  sold_on    date not null default frcs_today(),
  sku        text not null,
  qty        int  not null default 0,
  amt        numeric not null default 0,
  cost       numeric not null default 0,          -- 整筆成本（qty × 單件成本）
  note       text,
  txn_no     text,
  created_at timestamptz not null default now()
);
create index if not exists frcs_sales_store_on on frcs_sales(store, sold_on);

-- ---------------------------------------------------------------------
-- 6. 預購
-- ---------------------------------------------------------------------
create table if not exists frcs_preorders (
  no         text primary key,
  store      text not null references frcs_stores(code),
  sku        text not null,
  qty        int  not null default 1,
  price      numeric not null default 0,
  deposit    numeric not null default 0,
  stage      text not null default '收訂金',
  cust       text,
  member_phone text,                              -- 綁會員（可空）
  created_on date not null default frcs_today(),
  done_on    date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. 採購單（明細放 jsonb，跟前端結構一樣）
-- ---------------------------------------------------------------------
create table if not exists frcs_purchases (
  no          text primary key,
  store       text not null references frcs_stores(code),
  vendor      text,
  currency    text not null default 'TWD',
  rate        numeric not null default 1,
  freight     numeric not null default 0,
  duty        numeric not null default 0,
  stage       text not null default '已訂購',
  ordered_on  text,
  eta         text,
  items       jsonb not null default '[]'::jsonb,
  received_on date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 8. 開銷、待匯款、退換貨、調貨
-- ---------------------------------------------------------------------
create table if not exists frcs_expenses (
  id         uuid primary key default gen_random_uuid(),
  store      text not null references frcs_stores(code),
  spent_on   date not null default frcs_today(),
  cat        text not null,
  amt        numeric not null,
  who        text,
  note       text,
  created_at timestamptz not null default now()
);

create table if not exists frcs_topay (
  no         text primary key,
  store      text not null references frcs_stores(code),
  who        text,
  amt        numeric not null default 0,
  cat        text,
  paid       boolean not null default false,
  paid_on    date,
  created_at timestamptz not null default now()
);

create table if not exists frcs_returns (
  id         uuid primary key default gen_random_uuid(),
  store      text not null references frcs_stores(code),
  ret_on     date not null default frcs_today(),
  at_time    text,
  sku        text,
  name       text,
  qty        int  not null default 1,
  amt        numeric not null default 0,
  cost       numeric not null default 0,
  type       text not null default '退貨',
  reason     text,
  created_at timestamptz not null default now()
);

create table if not exists frcs_transfers (
  id         uuid primary key default gen_random_uuid(),
  from_store text not null references frcs_stores(code),
  to_store   text not null references frcs_stores(code),
  sku        text not null,
  name       text,
  qty        int  not null,
  moved_on   date not null default frcs_today(),
  note       text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 9. 日結：打烊對錢箱
-- ---------------------------------------------------------------------
create table if not exists frcs_day_close (
  id            uuid primary key default gen_random_uuid(),
  store         text not null references frcs_stores(code),
  closed_on     date not null default frcs_today(),
  by_pay        jsonb not null default '{}'::jsonb,  -- {"現金":1200,"刷卡":3000,...}
  txn_count     int not null default 0,
  cash_expected numeric not null default 0,
  cash_counted  numeric not null default 0,
  diff          numeric not null default 0,
  note          text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  unique (store, closed_on)
);

-- ---------------------------------------------------------------------
-- 10. 預設資料
-- ---------------------------------------------------------------------
insert into frcs_stores (code, name, sort_order) values ('FRCS', 'FRCS 台南', 0)
on conflict (code) do nothing;

insert into frcs_config (key, value) values ('pin', '1234')
on conflict (key) do nothing;
