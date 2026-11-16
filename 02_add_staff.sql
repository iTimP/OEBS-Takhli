-- ขั้นที่ 1: Supabase > Authentication > Users > Add user (ใส่อีเมล + รหัสผ่าน ติ๊ก Auto Confirm User)
-- ขั้นที่ 2: แก้อีเมล ชื่อ และแผนกด้านล่าง แล้วรันใน SQL Editor (ทำซ้ำได้ทีละคน)
insert into public.staff (user_id, full_name, dept)
select id, 'ชื่อ-นามสกุล เจ้าหน้าที่พัสดุ', 'พัสดุ'
from auth.users where email = 'stock@example.com'
on conflict (user_id) do update set full_name = excluded.full_name, dept = excluded.dept;
