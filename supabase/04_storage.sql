-- =====================================================================
-- FRCS INVENTORY · 04 商品圖片 Storage
--
-- bucket：frcs-photos
--   · 公開讀取（商品圖放在 <img src> 直接顯示，不是機密）
--   · 只有 FRCS 員工能上傳／覆蓋／刪除
--   · 檔名固定 items/<商品編號>.jpg，重傳就是覆蓋
-- 可重複執行。
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('frcs-photos', 'frcs-photos', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = true, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "frcs photos public read"  on storage.objects;
drop policy if exists "frcs photos staff insert" on storage.objects;
drop policy if exists "frcs photos staff update" on storage.objects;
drop policy if exists "frcs photos staff delete" on storage.objects;

create policy "frcs photos public read" on storage.objects
  for select using (bucket_id = 'frcs-photos');

create policy "frcs photos staff insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'frcs-photos' and frcs_is_staff());

create policy "frcs photos staff update" on storage.objects
  for update to authenticated
  using (bucket_id = 'frcs-photos' and frcs_is_staff())
  with check (bucket_id = 'frcs-photos' and frcs_is_staff());

create policy "frcs photos staff delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'frcs-photos' and frcs_is_staff());

-- storage policy 裡要叫得到 frcs_is_staff（03 收掉了 authenticated 的執行權，這裡開回來）
grant execute on function frcs_is_staff() to authenticated;
