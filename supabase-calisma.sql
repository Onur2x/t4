-- ============================================================
--  ÇALIŞMA SAATLERİ (t4)
--  Supabase SQL Editor > bu dosyayı çalıştır (bir kez)
--  supabase-setup.sql'den SONRA çalıştır.
-- ============================================================

create table if not exists public.servis_ayar (
  anahtar     text primary key,
  deger       text not null,
  guncellendi timestamptz not null default now()
);

alter table public.servis_ayar enable row level security;
-- Tarayıcı tabloya doğrudan erişemez; RPC'lerden okunur/yazılır.
revoke all on public.servis_ayar from anon, authenticated;

insert into public.servis_ayar (anahtar, deger) values
  ('calisma_bas', '09:00'),
  ('calisma_bit', '20:50')
on conflict (anahtar) do nothing;

-- Saat aralığı kontrolü (gece devreden aralıkları da destekler: 22:00 → 06:00)
create or replace function public.servis_acik_mi(p_bas time, p_bit time, p_simdi time)
returns boolean
language sql immutable as $$
  select case
    when p_bas <= p_bit then p_simdi >= p_bas and p_simdi <= p_bit
    else p_simdi >= p_bas or p_simdi <= p_bit
  end;
$$;

-- Durum: şu an açık mı? (Türkiye saatiyle, sunucu saatinden)
create or replace function public.servis_calisma_durumu()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_bas time;
  v_bit time;
  v_simdi time;
  v_acik boolean;
begin
  select deger::time into v_bas from public.servis_ayar where anahtar = 'calisma_bas';
  select deger::time into v_bit from public.servis_ayar where anahtar = 'calisma_bit';
  if v_bas is null then v_bas := '09:00'::time; end if;
  if v_bit is null then v_bit := '20:50'::time; end if;

  v_simdi := (now() at time zone 'Europe/Istanbul')::time;
  v_acik := public.servis_acik_mi(v_bas, v_bit, v_simdi);

  return jsonb_build_object(
    'ok', true,
    'bas', to_char(v_bas, 'HH24:MI'),
    'bit', to_char(v_bit, 'HH24:MI'),
    'simdi', to_char(v_simdi, 'HH24:MI'),
    'acik', v_acik
  );
end;
$$;
revoke all on function public.servis_calisma_durumu() from public;
grant execute on function public.servis_calisma_durumu() to anon, authenticated;

-- Yönetici: saatleri değiştir
create or replace function public.servis_ayar_guncelle(
  p_admin_sicil text, p_admin_hash text,
  p_bas text, p_bit text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v public.servis_personel;
  v_bas time;
  v_bit time;
begin
  select * into v from public.servis_admin_dogrula(p_admin_sicil, p_admin_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz');
  end if;

  begin
    v_bas := p_bas::time;
    v_bit := p_bit::time;
  exception when others then
    return jsonb_build_object('ok', false, 'mesaj', 'Saat biçimi hatalı (SS:DD)');
  end;

  if v_bas = v_bit then
    return jsonb_build_object('ok', false, 'mesaj', 'Başlangıç ve bitiş aynı olamaz');
  end if;

  insert into public.servis_ayar (anahtar, deger, guncellendi)
  values ('calisma_bas', to_char(v_bas, 'HH24:MI'), now())
  on conflict (anahtar) do update set deger = excluded.deger, guncellendi = now();

  insert into public.servis_ayar (anahtar, deger, guncellendi)
  values ('calisma_bit', to_char(v_bit, 'HH24:MI'), now())
  on conflict (anahtar) do update set deger = excluded.deger, guncellendi = now();

  return public.servis_calisma_durumu();
end;
$$;
revoke all on function public.servis_ayar_guncelle(text, text, text, text) from public;
grant execute on function public.servis_ayar_guncelle(text, text, text, text) to anon, authenticated;

-- Talep açmayı da sunucuda saat kontrolüne bağla
create or replace function public.servis_talep_iste(
  p_sicil text, p_hash text,
  p_gun date, p_saat time,
  p_vardiya text, p_yon text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v public.servis_personel;
  v_bas time;
  v_bit time;
begin
  select * into v from public.servis_dogrula(p_sicil, p_hash);
  if not found or v.sicil is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Yetkisiz — tekrar giriş yap');
  end if;

  select deger::time into v_bas from public.servis_ayar where anahtar = 'calisma_bas';
  select deger::time into v_bit from public.servis_ayar where anahtar = 'calisma_bit';
  if v_bas is null then v_bas := '09:00'::time; end if;
  if v_bit is null then v_bit := '20:50'::time; end if;

  if not public.servis_acik_mi(v_bas, v_bit, (now() at time zone 'Europe/Istanbul')::time) then
    return jsonb_build_object('ok', false, 'kapali', true,
      'mesaj', 'Uygulama ' || to_char(v_bas,'HH24:MI') || ' – ' || to_char(v_bit,'HH24:MI') || ' arası çalışmaktadır');
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

notify pgrst, 'reload schema';

-- KONTROL
-- select * from public.servis_ayar;
-- select public.servis_calisma_durumu();
