-- ============================================================
--  SERVİS TALEBİ UYGULAMASI (t4) — Supabase kurulum
--  Yeni Supabase projesinde: SQL Editor > bu dosyayı çalıştır
-- ============================================================

-- Hash üretimi sunucuda da yapılabilsin (ilk giriş doğrulaması için)
create extension if not exists pgcrypto with schema extensions;

-- İstemciyle AYNI hash: sha256('t4|sicil|sifre|servis')
create or replace function public.servis_hash(p_sicil text, p_sifre text)
returns text
language sql immutable
set search_path = extensions, public
as $$
  select encode(digest('t4|' || p_sicil || '|' || p_sifre || '|servis', 'sha256'), 'hex');
$$;

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

-- Tabloya DOĞRUDAN erişim yok. Tüm okuma/yazma RPC'lerden geçer ve
-- her RPC sicil+şifre (hash) doğrular. Böylece anahtarı alan biri
-- tüm talepleri listeleyemez.
revoke all on public.servis_talep from anon, authenticated;

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

  -- İlk giriş: şifre henüz belirlenmemiş → şifre SİCİL olmalı (sunucuda doğrulanır)
  if (not r.sifre_degisti) or coalesce(r.sifre_hash, '') = '' then
    if p_hash <> public.servis_hash(p_sicil, p_sicil) then
      return jsonb_build_object('ok', false, 'mesaj', 'İlk girişte şifre = sicil numaran olmalı');
    end if;
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

-- ---------- 4) ŞİFRE KAYDET (sadece ilk giriş) ----------
-- Güvenlik: yalnızca şifresi HENÜZ belirlenmemiş hesap için çalışır.
-- Böylece biri başkasının hesabına şifre koyup ele geçiremez.
-- Mevcut şifreyi değiştirmek için yönetici sıfırlaması gerekir.
create or replace function public.servis_sifre_kaydet(p_sicil text, p_hash text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_sicil is null or p_hash is null or length(p_hash) < 8 then
    return false;
  end if;
  if p_hash = public.servis_hash(p_sicil, p_sicil) then
    return false;
  end if;
  update public.servis_personel
     set sifre_hash = p_hash,
         sifre_degisti = true,
         basarisiz = 0,
         kilitli = false,
         kilit_bitis = null
   where sicil = p_sicil
     and sifre_degisti = false;
  return found;
end;
$$;

revoke all on function public.servis_sifre_kaydet(text, text) from public;
grant execute on function public.servis_sifre_kaydet(text, text) to anon, authenticated;

-- ---------- 5) ADMIN YARDIMCILARI ----------
-- Admin kimlik doğrulaması: hash eşleşmeli ve admin=true olmalı
drop function if exists public.servis_admin_dogrula(text, text);
create or replace function public.servis_admin_dogrula(p_sicil text, p_hash text)
returns setof public.servis_personel
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
  if not found or v_admin.sicil is null then
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
  if not found or v_admin.sicil is null then
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
  if not found or v_admin.sicil is null then
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
  if not found or v_admin.sicil is null then
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

-- ---------- 7) ERİŞİM KURALI ----------
-- Bu uygulamaya SADECE servis_personel tablosundaki siciller girebilir.
-- Kimlik doğrulaması servis_giris() ile yapılır; listede olmayan reddedilir.

-- ---------- 8) TALEP YAZMA (yalnızca giriş yapmış kişi) ----------
-- Tarayıcı tabloya DOĞRUDAN yazamaz. Yazma RPC ile ve şifre doğrulamasıyla yapılır.
revoke insert, update, delete on public.servis_talep from anon, authenticated;

drop function if exists public.servis_dogrula(text, text);
create or replace function public.servis_dogrula(p_sicil text, p_hash text)
returns setof public.servis_personel
language sql security definer set search_path = public as $$
  select * from public.servis_personel
   where sicil = p_sicil and aktif = true and sifre_degisti = true
     and sifre_hash = p_hash
   limit 1;
$$;
revoke all on function public.servis_dogrula(text, text) from public;

create or replace function public.servis_talep_iste(
  p_sicil text, p_hash text,
  p_gun date, p_saat time,
  p_vardiya text, p_yon text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.servis_personel;
begin
  select * into v from public.servis_dogrula(p_sicil, p_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz — tekrar giriş yap');
  end if;
  if p_vardiya not in ('sabah', 'aksam') then
    return jsonb_build_object('ok', false, 'mesaj', 'Vardiya seçilmedi');
  end if;
  if p_yon not in ('karadeniz', 'mselam') then
    return jsonb_build_object('ok', false, 'mesaj', 'Yön seçilmedi');
  end if;

  insert into public.servis_talep (sicil, ad, gun, saat, vardiya, yon, durum)
  values (v.sicil, v.ad, p_gun, p_saat, p_vardiya, p_yon, 'aktif')
  on conflict (sicil, gun) do update
    set ad         = excluded.ad,
        saat       = excluded.saat,
        vardiya    = excluded.vardiya,
        yon        = excluded.yon,
        durum      = 'aktif',
        iptal_gun  = null,
        iptal_saat = null,
        guncellendi = now();

  return jsonb_build_object('ok', true, 'ad', v.ad);
end;
$$;
revoke all on function public.servis_talep_iste(text, text, date, time, text, text) from public;
grant execute on function public.servis_talep_iste(text, text, date, time, text, text) to anon, authenticated;

create or replace function public.servis_talep_iptal(
  p_sicil text, p_hash text,
  p_gun date, p_saat time
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.servis_personel;
        v_say integer;
begin
  select * into v from public.servis_dogrula(p_sicil, p_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz — tekrar giriş yap');
  end if;

  update public.servis_talep
     set durum = 'iptal',
         iptal_gun = p_gun,
         iptal_saat = p_saat,
         guncellendi = now()
   where sicil = v.sicil and gun = p_gun and durum = 'aktif';

  get diagnostics v_say = row_count;
  if v_say = 0 then
    return jsonb_build_object('ok', false, 'mesaj', 'Bugün için aktif talebin yok');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.servis_talep_iptal(text, text, date, time) from public;
grant execute on function public.servis_talep_iptal(text, text, date, time) to anon, authenticated;

-- ---------- 9) TALEP OKUMA (yalnızca kendi talepleri / yetkili yönetici) ----------
create or replace function public.servis_taleplerim(p_sicil text, p_hash text, p_gun date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.servis_personel;
begin
  select * into v from public.servis_dogrula(p_sicil, p_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  return jsonb_build_object('ok', true, 'liste', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'gun', gun, 'saat', saat, 'vardiya', vardiya, 'yon', yon,
      'durum', durum, 'iptal_gun', iptal_gun, 'iptal_saat', iptal_saat
    ) order by gun desc, saat desc)
    from public.servis_talep
    where sicil = v.sicil
      and (p_gun is null or gun = p_gun)
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.servis_taleplerim(text, text, date) from public;
grant execute on function public.servis_taleplerim(text, text, date) to anon, authenticated;

create or replace function public.servis_admin_talepler(
  p_admin_sicil text, p_admin_hash text,
  p_bas date, p_bit date,
  p_vardiya text default null, p_yon text default null,
  p_durum text default null, p_ara text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.servis_personel;
begin
  select * into v from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;
  return jsonb_build_object('ok', true, 'liste', coalesce((
    select jsonb_agg(x order by x->>'gun' desc, x->>'saat' desc)
    from (
      select jsonb_build_object(
        'id', id, 'sicil', sicil, 'ad', ad, 'gun', gun, 'saat', saat,
        'vardiya', vardiya, 'yon', yon, 'durum', durum,
        'iptal_gun', iptal_gun, 'iptal_saat', iptal_saat
      ) as x
      from public.servis_talep
      where gun between p_bas and p_bit
        and (p_vardiya is null or vardiya = p_vardiya)
        and (p_yon is null or yon = p_yon)
        and (p_durum is null or durum = p_durum)
        and (p_ara is null or p_ara = '' or sicil ilike '%' || p_ara || '%' or ad ilike '%' || p_ara || '%')
      limit 2000
    ) t
  ), '[]'::jsonb));
end;
$$;
revoke all on function public.servis_admin_talepler(text, text, date, date, text, text, text, text) from public;
grant execute on function public.servis_admin_talepler(text, text, date, date, text, text, text, text) to anon, authenticated;

-- ---------- 10) KİŞİ LİSTESİ ----------
-- seed_servis_personel.sql dosyasını da çalıştır (102 kişi).
-- Bu dosya servis_isimler.xlsx'ten üretildi.




-- ============================================================
--  KURULUM DOĞRULAMA (elle çalıştır)
-- ============================================================
-- 1) Fonksiyonlar var mı?
-- select proname from pg_proc where proname like 'servis\_%' order by 1;
--
-- 2) Hash fonksiyonu istemciyle aynı mı? (3525 için beklenen değer çıkmalı)
-- select public.servis_hash('3525','3525');
--
-- 3) Tabloya doğrudan erişim kapalı mı? (hata vermeli)
-- begin; set local role anon; select * from public.servis_talep limit 1; rollback;
--
-- 4) Yanlış şifreyle yönetici listesi (bos liste / Yetkisiz dönmeli)
-- select public.servis_personel_liste('1000','yanlis');
--
-- 5) Önbelleği yenile
notify pgrst, 'reload schema';