-- ระบบยืม-คืนพัสดุ: สร้างตาราง ฟังก์ชัน และสิทธิ์ (รันใน Supabase > SQL Editor)
create table if not exists public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  dept text not null default 'พัสดุ'
);
create table if not exists public.items (
  id bigint generated always as identity primary key,
  code text not null,
  name text not null,
  type text not null default 'วัสดุสำนักงาน',
  spec text, serial text,
  unit text not null default 'ชิ้น',
  place text,
  cond text default 'ใช้งานได้ดี',
  total int not null check (total >= 0),
  created_at timestamptz not null default now()
);
create unique index if not exists items_code_uq on public.items (lower(code));
create table if not exists public.loans (
  id bigint generated always as identity primary key,
  item_id bigint references public.items(id) on delete set null,
  item_name text,
  person text not null,
  qty int not null check (qty > 0),
  borrow_date date not null,
  due_date date not null,
  return_date date,
  received_by text,
  created_at timestamptz not null default now(),
  constraint loans_dates check (due_date >= borrow_date)
);
create index if not exists loans_item_idx on public.loans(item_id);
create index if not exists loans_open_idx on public.loans(return_date);
create table if not exists public.receipts (
  id bigint generated always as identity primary key,
  item_id bigint references public.items(id) on delete set null,
  item_code text, item_name text,
  qty int not null check (qty > 0),
  receive_date date not null,
  method text, fund text, doc_no text, vendor text,
  unit_price numeric(14,2) default 0,
  note text,
  created_by_name text,
  created_at timestamptz not null default now()
);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid())
$$;

-- ตรวจจำนวนว่างก่อนบันทึกการยืม (ล็อกแถวพัสดุกันยืมซ้อน)
create or replace function public.trg_loan_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_total int; v_name text; v_out int;
begin
  select total, name into v_total, v_name from items where id = new.item_id for update;
  if not found then raise exception 'ไม่พบพัสดุรายการนี้'; end if;
  select coalesce(sum(qty),0) into v_out from loans where item_id = new.item_id and return_date is null;
  if new.qty > v_total - v_out then
    raise exception 'จำนวนไม่พอ ว่างเพียง % ชิ้น', v_total - v_out;
  end if;
  new.item_name := v_name; new.return_date := null; new.received_by := null;
  return new;
end $$;
drop trigger if exists loan_before_insert on public.loans;
create trigger loan_before_insert before insert on public.loans
  for each row execute function public.trg_loan_before_insert();

-- กันลบ/ลดจำนวนต่ำกว่าที่ถูกยืมอยู่
create or replace function public.trg_items_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_out int;
begin
  select coalesce(sum(qty),0) into v_out from loans where item_id = old.id and return_date is null;
  if tg_op = 'DELETE' then
    if v_out > 0 then raise exception 'ลบไม่ได้ ยังมีผู้ยืมพัสดุนี้อยู่'; end if;
    return old;
  end if;
  if new.total < v_out then
    raise exception 'จำนวนทั้งหมดต้องไม่น้อยกว่าที่ถูกยืมอยู่ (% ชิ้น)', v_out;
  end if;
  return new;
end $$;
drop trigger if exists items_guard on public.items;
create trigger items_guard before update or delete on public.items
  for each row execute function public.trg_items_guard();

-- ลงทะเบียนรับพัสดุ (เจ้าหน้าที่เท่านั้น) ถ้าเลขที่พัสดุซ้ำจะบวกจำนวนเพิ่ม
create or replace function public.register_receipt(
  p_code text, p_name text, p_type text, p_spec text, p_serial text, p_unit text,
  p_place text, p_cond text, p_qty int, p_date date, p_method text, p_fund text,
  p_doc text, p_vendor text, p_price numeric, p_note text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_name text; v_by text;
begin
  if not is_staff() then raise exception 'เฉพาะเจ้าหน้าที่เท่านั้น'; end if;
  if p_qty < 1 then raise exception 'จำนวนต้องมากกว่า 0'; end if;
  select full_name into v_by from staff where user_id = auth.uid();
  select id, name into v_id, v_name from items where lower(code) = lower(trim(p_code)) for update;
  if found then
    update items set total = total + p_qty where id = v_id;
  else
    insert into items(code,name,type,spec,serial,unit,place,cond,total)
    values (trim(p_code), trim(p_name), p_type, nullif(trim(p_spec),''), nullif(trim(p_serial),''),
            coalesce(nullif(trim(p_unit),''),'ชิ้น'), nullif(trim(p_place),''), p_cond, p_qty)
    returning id, name into v_id, v_name;
  end if;
  insert into receipts(item_id,item_code,item_name,qty,receive_date,method,fund,doc_no,vendor,unit_price,note,created_by_name)
  values (v_id, trim(p_code), v_name, p_qty, p_date, p_method, p_fund, nullif(trim(p_doc),''),
          nullif(trim(p_vendor),''), coalesce(p_price,0), nullif(trim(p_note),''), v_by);
  return v_id;
end $$;

-- รับคืนพัสดุ (เจ้าหน้าที่เท่านั้น)
create or replace function public.return_loan(p_loan_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'เฉพาะเจ้าหน้าที่เท่านั้น'; end if;
  update loans set return_date = (now() at time zone 'Asia/Bangkok')::date,
         received_by = (select full_name from staff where user_id = auth.uid())
   where id = p_loan_id and return_date is null;
  if not found then raise exception 'ไม่พบรายการยืมที่ยังไม่คืน'; end if;
end $$;

-- Row Level Security
alter table public.staff    enable row level security;
alter table public.items    enable row level security;
alter table public.loans    enable row level security;
alter table public.receipts enable row level security;

drop policy if exists staff_self on public.staff;
create policy staff_self on public.staff for select to authenticated using (user_id = auth.uid());

drop policy if exists items_read on public.items;
create policy items_read on public.items for select to anon, authenticated using (true);
drop policy if exists items_ins on public.items;
create policy items_ins on public.items for insert to authenticated with check (public.is_staff());
drop policy if exists items_upd on public.items;
create policy items_upd on public.items for update to authenticated using (public.is_staff()) with check (public.is_staff());
drop policy if exists items_del on public.items;
create policy items_del on public.items for delete to authenticated using (public.is_staff());

-- ทุกคนเห็นรายการที่ยังยืมอยู่ ประวัติการคืนเห็นเฉพาะเจ้าหน้าที่
drop policy if exists loans_read on public.loans;
create policy loans_read on public.loans for select to anon, authenticated
  using (return_date is null or public.is_staff());
drop policy if exists loans_borrow on public.loans;
create policy loans_borrow on public.loans for insert to anon, authenticated
  with check (return_date is null and received_by is null);

drop policy if exists receipts_read on public.receipts;
create policy receipts_read on public.receipts for select to authenticated using (public.is_staff());

grant usage on schema public to anon, authenticated;
grant select on public.items to anon, authenticated;
grant insert, update, delete on public.items to authenticated;
grant select, insert on public.loans to anon, authenticated;
grant select on public.receipts, public.staff to authenticated;
grant execute on function public.register_receipt(text,text,text,text,text,text,text,text,int,date,text,text,text,text,numeric,text) to authenticated;
grant execute on function public.return_loan(bigint) to authenticated;
