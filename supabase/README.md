# FRCS INVENTORY · 後端部署（Supabase）

後端從 Google Apps Script 換成 Supabase，做法跟 FEEDO ERP 一樣：
所有表 RLS deny-all，前端只能呼叫 `frcs_*` RPC；庫存是流水帳；寫入帶 id 可重送。

## 一次性建置

1. 到 https://supabase.com 開一個新專案（Region 選 Tokyo 或 Singapore）。
2. Dashboard → SQL Editor，**依序**執行：

| 順序 | 檔案 | 做什麼 |
|---|---|---|
| 1 | `01_schema.sql` | 建表、權限函式、預設店別 FRCS、預設 PIN 1234 |
| 2 | `02_rpc.sql` | 所有 RPC（載入、結帳、入庫、盤點、預購、採購、開銷…） |
| 3 | `03_security.sql` | RLS deny-all，只開放 RPC 給登入者 |
| 4 | `04_storage.sql` | 商品圖片 bucket `frcs-photos` 與上傳權限 |
| 5 | `05_purchase_detail.sql` | 廠商主檔、採購單備註、物流單號、可刪除（已部署 2026-10-30；全新安裝 01～04 已含） |

順序不能顛倒（03 要先有 01、02 的物件才收得掉權限；04 要用到 01 的 `frcs_is_staff`）。

### 貼進 SQL Editor 的編碼陷阱

```bash
LC_ALL=en_US.UTF-8 pbcopy < supabase/01_schema.sql
```

少了 `LC_ALL`，中文字串貼進去會變亂碼，SQL 照樣建得起來但 `'退貨'`、`'已收尾款'` 這種比對永遠比不中。
驗法（純 ASCII）：

```sql
select proname, prosrc like '%'||chr(36864)||chr(36008)||'%' from pg_proc where proname like 'frcs_%';
```

（`chr(36864)||chr(36008)` = 「退貨」。）

## 建立帳號

1. Dashboard → Authentication → Users → **Add user**，填 email 和密碼（Auto Confirm 勾起來）。
2. SQL Editor 執行（email 換成剛建的）：

```sql
insert into frcs_staff (user_id, name, role)
select id, 'Francis', 'owner' from auth.users where email = 'you@example.com'
on conflict (user_id) do update set role = 'owner', active = true;
```

店員帳號 role 填 `'staff'`：看不到進價、帳務、採購，後端連資料都不送；可以建商品、拍照、改品名分類，但售價只有建新款時能填，之後改價限老闆（後端擋）。

## 前端設定

`index.html` 最上面：

```js
const SUPABASE_URL  = "https://xxxx.supabase.co";
const SUPABASE_ANON = "sb_publishable_...";   // Project Settings → API → anon public
```

Dashboard → Authentication → URL Configuration → Site URL 填 `https://feedotea.github.io/frcs-erp/`。

## 資料模型要點

- **款式 vs SKU**：`frcs_items` 一列是一個 SKU（條碼），`style_no` 把同款的尺寸顏色串起來；單一規格的商品 `style_no = no`。
  新增／編輯走 `frcs_save_style`，整款一次存；SKU 條碼 = 款式編號 + 兩位流水（21497 → 2149701、2149702…）。
- **庫存**是 `frcs_stock_moves` 加總，`frcs_v_stock` 是現況；異動種類見 01 的註解。
- **作廢**（`frcs_void_txn`，限老闆、限當天、日結前）：刪 `frcs_sales`、庫存反向寫一筆 `void`、單留著標 `voided`。
- **日結**（`frcs_day_close`）：各付款方式小計由後端從 `frcs_txns` 重算，前端只送實點現金。一天一筆，重做會覆蓋。
- **預購**可綁 `member_phone`；`frcs_member_history` 給會員頁看購買與預購紀錄。

## 角色與 PIN

- 帳號 role 是 owner：App 開起來先是店員畫面，按 🔒 輸 PIN 才解鎖成本與帳務（共用 iPad 用）。
- 帳號 role 是 staff：沒有 🔒，PIN 也沒用，後端不會送成本。
- PIN 存在 `frcs_config`，前端拿不到，只能用 `frcs_check_pin` 比對。

## 之後改資料庫

新功能寫成 `05_xxx.sql`、`06_xxx.sql` 往下編，每支可重複執行；改了函式簽名要先 `drop function`。
