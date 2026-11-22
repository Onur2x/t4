-- ============================================================
--  SERVİS TALEBİ UYGULAMASI (t4) — Supabase kurulum
--  Yeni Supabase projesinde: SQL Editor > bu dosyayı çalıştır
-- ============================================================

-- ---------- 1) PERSONEL + ŞİFRE ----------
create table if not exists public.servis_personel (
  sicil        text primary key,
  ad           text not null,
  aktif        boolean not null default true,
  admin        boolean not null default false,
  sifre_hash   text    not null default '',
  sifre_degisti boolean not null default false,
  basarisiz    integer not null default 0,
  kilitli      boolean not null default false,
  kilit_bitis  timestamptz,
  son_deneme   timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.servis_personel enable row level security;

-- Tarayıcı bu tabloya DOĞRUDAN erişemez. Her şey aşağıdaki RPC'lerden geçer.
drop policy if exists "sp_anon" on public.servis_personel;
revoke all on public.servis_personel from anon, authenticated;

-- ---------- 2) SERVİS TALEPLERİ ----------
create table if not exists public.servis_talep (
  id           bigint generated always as identity primary key,
  sicil        text not null,
  ad           text,
  gun          date not null,
  saat         time not null,
  vardiya      text not null check (vardiya in ('sabah','aksam')),
  yon          text not null check (yon in ('karadeniz','mselam')),
  durum        text not null default 'aktif' check (durum in ('aktif','iptal')),
  iptal_gun    date,
  iptal_saat   time,
  created_at   timestamptz not null default now(),
  guncellendi  timestamptz not null default now()
);

-- Bir kişi bir gün için tek talep (tekrar talepte güncellenir)
create unique index if not exists servis_talep_tek on public.servis_talep (sicil, gun);
create index if not exists servis_talep_gun on public.servis_talep (gun desc);
create index if not exists servis_talep_durum on public.servis_talep (durum);

alter table public.servis_talep enable row level security;

drop policy if exists "st_read"  on public.servis_talep;
drop policy if exists "st_insert" on public.servis_talep;
drop policy if exists "st_update" on public.servis_talep;
drop policy if exists "st_delete" on public.servis_talep;

create policy "st_read"   on public.servis_talep for select to anon, authenticated using (true);
create policy "st_insert" on public.servis_talep for insert to anon, authenticated with check (true);
create policy "st_update" on public.servis_talep for update to anon, authenticated using (true) with check (true);
create policy "st_delete" on public.servis_talep for delete to authenticated using (true);

grant select, insert, update on public.servis_talep to anon, authenticated;

-- ---------- 3) GİRİŞ ----------
-- Dönen: { ok, mod: 'ilk'|'giris', ad, admin, mesaj, kilitli, kalan_dk }
create or replace function public.servis_giris(p_sicil text, p_hash text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r public.servis_personel%rowtype;
  v_kalan integer;
  v_yeni integer;
begin
  select * into r from public.servis_personel where sicil = p_sicil;
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Sicil bulunamadı');
  end if;
  if not r.aktif then
    return jsonb_build_object('ok', false, 'mesaj', 'Hesap pasif');
  end if;

  if r.kilitli then
    if r.kilit_bitis is not null and r.kilit_bitis <= now() then
      update public.servis_personel
         set basarisiz = 0, kilitli = false, kilit_bitis = null
       where sicil = p_sicil;
    else
      v_kalan := greatest(1, ceil(extract(epoch from (r.kilit_bitis - now())) / 60));
      return jsonb_build_object('ok', false, 'kilitli', true, 'kalan_dk', v_kalan,
                                'mesaj', 'Çok fazla hatalı deneme — ' || v_kalan || ' dk sonra dene');
    end if;
  end if;

  -- İlk giriş: şifre henüz belirlenmemiş
  if (not r.sifre_degisti) or coalesce(r.sifre_hash, '') = '' then
    return jsonb_build_object('ok', true, 'mod', 'ilk', 'ad', r.ad, 'admin', r.admin);
  end if;

  -- Normal giriş
  if r.sifre_hash = p_hash then
    update public.servis_personel
       set basarisiz = 0, kilitli = false, kilit_bitis = null, son_deneme = now()
     where sicil = p_sicil;
    return jsonb_build_object('ok', true, 'mod', 'giris', 'ad', r.ad, 'admin', r.admin);
  end if;

  -- Hatalı şifre
  v_yeni := case
              when r.son_deneme is not null and now() - r.son_deneme > interval '15 minutes' then 1
              else r.basarisiz + 1
            end;

  update public.servis_personel
     set basarisiz   = v_yeni,
         kilitli     = (v_yeni >= 5),
         kilit_bitis = case when v_yeni >= 5 then now() + interval '15 minutes' else null end,
         son_deneme  = now()
   where sicil = p_sicil;

  if v_yeni >= 5 then
    return jsonb_build_object('ok', false, 'kilitli', true, 'kalan_dk', 15,
                              'mesaj', 'Çok fazla hatalı deneme — 15 dk kilitlendi');
  end if;
  return jsonb_build_object('ok', false, 'mesaj', 'Şifre hatalı');
end;
$$;

revoke all on function public.servis_giris(text, text) from public;
grant execute on function public.servis_giris(text, text) to anon, authenticated;

-- ---------- 4) ŞİFRE KAYDET (ilk giriş) ----------
create or replace function public.servis_sifre_kaydet(p_sicil text, p_hash text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_sicil is null or p_hash is null or length(p_hash) < 8 then
    return false;
  end if;
  update public.servis_personel
     set sifre_hash = p_hash,
         sifre_degisti = true,
         basarisiz = 0,
         kilitli = false,
         kilit_bitis = null
   where sicil = p_sicil;
  return found;
end;
$$;

revoke all on function public.servis_sifre_kaydet(text, text) from public;
grant execute on function public.servis_sifre_kaydet(text, text) to anon, authenticated;

-- ---------- 5) ADMIN YARDIMCILARI ----------
-- Admin kimlik doğrulaması: hash eşleşmeli ve admin=true olmalı
create or replace function public.servis_admin_dogrula(p_sicil text, p_hash text)
returns public.servis_personel
language sql security definer set search_path = public as $$
  select * from public.servis_personel
   where sicil = p_sicil and admin = true and aktif = true
     and sifre_degisti = true and sifre_hash = p_hash
   limit 1;
$$;

create or replace function public.servis_personel_liste(p_admin_sicil text, p_admin_hash text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin public.servis_personel;
begin
  select * into v_admin from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  return jsonb_build_object('ok', true, 'liste', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sicil', sicil, 'ad', ad, 'aktif', aktif, 'admin', admin,
      'sifre_degisti', sifre_degisti, 'kilitli', kilitli,
      'basarisiz', basarisiz, 'created_at', created_at
    ) order by sicil)
    from public.servis_personel
  ), '[]'::jsonb));
end;
$$;

create or replace function public.servis_personel_ekle(
  p_admin_sicil text, p_admin_hash text,
  p_sicil text, p_ad text, p_admin boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin public.servis_personel;
begin
  select * into v_admin from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  if coalesce(trim(p_sicil), '') = '' or coalesce(trim(p_ad), '') = '' then
    return jsonb_build_object('ok', false, 'mesaj', 'Sicil ve ad gerekli');
  end if;
  insert into public.servis_personel (sicil, ad, admin)
  values (trim(p_sicil), trim(p_ad), coalesce(p_admin, false))
  on conflict (sicil) do update set ad = excluded.ad, admin = excluded.admin;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.servis_personel_durum(
  p_admin_sicil text, p_admin_hash text, p_sicil text, p_aktif boolean
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin public.servis_personel;
begin
  select * into v_admin from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  update public.servis_personel set aktif = p_aktif where sicil = p_sicil;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.servis_sifre_sifirla(
  p_admin_sicil text, p_admin_hash text, p_sicil text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin public.servis_personel;
begin
  select * into v_admin from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  update public.servis_personel
     set sifre_hash = '', sifre_degisti = false, basarisiz = 0,
         kilitli = false, kilit_bitis = null
   where sicil = p_sicil;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.servis_admin_dogrula(text, text) from public;
revoke all on function public.servis_personel_liste(text, text) from public;
revoke all on function public.servis_personel_ekle(text, text, text, text, boolean) from public;
revoke all on function public.servis_personel_durum(text, text, text, boolean) from public;
revoke all on function public.servis_sifre_sifirla(text, text, text) from public;

grant execute on function public.servis_personel_liste(text, text) to anon, authenticated;
grant execute on function public.servis_personel_ekle(text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.servis_personel_durum(text, text, text, boolean) to anon, authenticated;
grant execute on function public.servis_sifre_sifirla(text, text, text) to anon, authenticated;

-- ---------- 6) İLK YÖNETİCİ ----------
-- İlk giriş: sicil 1000, şifre 1000 → sonra kendi şifreni belirle.
insert into public.servis_personel (sicil, ad, admin)
values ('1000', 'Yönetici', true)
on conflict (sicil) do nothing;

-- ÖRNEK toplu personel (kendi listenle değiştir):
-- insert into public.servis_personel (sicil, ad) values
--  ('1001','Ahmet YILMAZ'),
--  ('1002','Ayşe KAYA')
-- on conflict (sicil) do nothing;
