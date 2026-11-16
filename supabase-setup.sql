-- PixelCart Supabase foundation
-- Run this in Supabase SQL Editor after the existing public.user_roles table and
-- customer-role signup trigger have been created.
-- Do NOT put a service_role key in the website.

create or replace function public.pixelcart_is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = auth.uid()
      and ur.role = 'owner'
  );
$$;

revoke all on function public.pixelcart_is_owner() from public;
grant execute on function public.pixelcart_is_owner() to authenticated;

create table if not exists public.pixelcart_categories (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.pixelcart_products (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.pixelcart_orders (
  id text primary key,
  customer_id uuid references auth.users(id) on delete set null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create table if not exists public.pixelcart_reviews (
  id text primary key,
  product_id text not null,
  customer_id uuid references auth.users(id) on delete set null,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create table if not exists public.pixelcart_delivery_fees (
  country text primary key,
  fee numeric(12,3) not null check (fee >= 0)
);
create table if not exists public.pixelcart_store_settings (
  id text primary key default 'main' check (id = 'main'),
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- QR tokens are random, unguessable values. The QR must contain the token,
-- not the discount's human-readable code.
create table if not exists public.pixelcart_discounts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  percent integer not null check (percent between 1 and 90),
  qr_token uuid not null unique default gen_random_uuid(),
  active boolean not null default true,
  expires_at timestamptz,
  max_claims integer check (max_claims is null or max_claims > 0),
  claim_count integer not null default 0 check (claim_count >= 0),
  created_at timestamptz not null default now()
);
create table if not exists public.pixelcart_customer_discounts (
  user_id uuid not null references auth.users(id) on delete cascade,
  discount_id uuid not null references public.pixelcart_discounts(id) on delete cascade,
  saved_at timestamptz not null default now(),
  redeemed_at timestamptz,
  primary key (user_id, discount_id)
);

alter table public.pixelcart_categories enable row level security;
alter table public.pixelcart_products enable row level security;
alter table public.pixelcart_orders enable row level security;
alter table public.pixelcart_reviews enable row level security;
alter table public.pixelcart_delivery_fees enable row level security;
alter table public.pixelcart_store_settings enable row level security;
alter table public.pixelcart_discounts enable row level security;
alter table public.pixelcart_customer_discounts enable row level security;

-- Public storefront reads.
drop policy if exists "PixelCart categories public read" on public.pixelcart_categories;
create policy "PixelCart categories public read" on public.pixelcart_categories
for select to anon, authenticated using (true);
drop policy if exists "PixelCart products public read" on public.pixelcart_products;
create policy "PixelCart products public read" on public.pixelcart_products
for select to anon, authenticated using (true);
drop policy if exists "PixelCart fees public read" on public.pixelcart_delivery_fees;
create policy "PixelCart fees public read" on public.pixelcart_delivery_fees
for select to anon, authenticated using (true);
drop policy if exists "PixelCart settings public read" on public.pixelcart_store_settings;
create policy "PixelCart settings public read" on public.pixelcart_store_settings
for select to anon, authenticated using (true);
drop policy if exists "PixelCart reviews public read" on public.pixelcart_reviews;
create policy "PixelCart reviews public read" on public.pixelcart_reviews
for select to anon, authenticated using (true);

-- Only the verified owner can alter store catalogue/configuration.
drop policy if exists "PixelCart categories owner manage" on public.pixelcart_categories;
create policy "PixelCart categories owner manage" on public.pixelcart_categories
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());
drop policy if exists "PixelCart products owner manage" on public.pixelcart_products;
create policy "PixelCart products owner manage" on public.pixelcart_products
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());
drop policy if exists "PixelCart fees owner manage" on public.pixelcart_delivery_fees;
create policy "PixelCart fees owner manage" on public.pixelcart_delivery_fees
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());
drop policy if exists "PixelCart settings owner manage" on public.pixelcart_store_settings;
create policy "PixelCart settings owner manage" on public.pixelcart_store_settings
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());
drop policy if exists "PixelCart discounts owner manage" on public.pixelcart_discounts;
create policy "PixelCart discounts owner manage" on public.pixelcart_discounts
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());

-- Customers may submit reviews only under their own authenticated account.
drop policy if exists "PixelCart customer review insert" on public.pixelcart_reviews;
create policy "PixelCart customer review insert" on public.pixelcart_reviews
for insert to authenticated with check (customer_id = auth.uid());
drop policy if exists "PixelCart owner review manage" on public.pixelcart_reviews;
create policy "PixelCart owner review manage" on public.pixelcart_reviews
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());

-- Orders are private: owner sees all; a customer sees only their own.
-- There is intentionally NO anon insert/select policy. Guest checkout must be
-- routed through a validated server-side Edge Function before it is enabled.
drop policy if exists "PixelCart order owner or customer read" on public.pixelcart_orders;
create policy "PixelCart order owner or customer read" on public.pixelcart_orders
for select to authenticated
using (public.pixelcart_is_owner() or customer_id = auth.uid());
drop policy if exists "PixelCart customer order insert" on public.pixelcart_orders;
create policy "PixelCart customer order insert" on public.pixelcart_orders
for insert to authenticated
with check (customer_id = auth.uid());
drop policy if exists "PixelCart owner order manage" on public.pixelcart_orders;
create policy "PixelCart owner order manage" on public.pixelcart_orders
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());

-- A signed-in customer can see only discounts they have saved.
drop policy if exists "PixelCart customer saved discounts read" on public.pixelcart_customer_discounts;
create policy "PixelCart customer saved discounts read" on public.pixelcart_customer_discounts
for select to authenticated using (user_id = auth.uid() or public.pixelcart_is_owner());
drop policy if exists "PixelCart owner saved discounts read" on public.pixelcart_customer_discounts;
create policy "PixelCart owner saved discounts read" on public.pixelcart_customer_discounts
for all to authenticated using (public.pixelcart_is_owner())
with check (public.pixelcart_is_owner());

-- QR scanning calls this RPC. It requires login, checks validity/claim limits,
-- and saves the discount to the caller's account. Re-scanning is harmless.
create or replace function public.pixelcart_claim_discount(p_qr_token uuid)
returns table(discount_id uuid, code text, percent integer, saved boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_discount public.pixelcart_discounts%rowtype;
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in to save a discount to your account.';
  end if;

  select * into v_discount
  from public.pixelcart_discounts
  where qr_token = p_qr_token
    and active = true
    and (expires_at is null or expires_at > now())
    and (max_claims is null or claim_count < max_claims)
  for update;

  if not found then
    raise exception 'This discount QR code is invalid, expired, or no longer available.';
  end if;

  insert into public.pixelcart_customer_discounts(user_id, discount_id)
  values (auth.uid(), v_discount.id)
  on conflict (user_id, discount_id) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted > 0 then
    update public.pixelcart_discounts
    set claim_count = claim_count + 1
    where id = v_discount.id;
  end if;

  return query select v_discount.id, v_discount.code, v_discount.percent, (v_inserted > 0);
end;
$$;

revoke all on function public.pixelcart_claim_discount(uuid) from public;
grant execute on function public.pixelcart_claim_discount(uuid) to authenticated;

-- The discount list exposes only saved discount details to the account owner.
drop policy if exists "PixelCart customer discount details read" on public.pixelcart_discounts;
create policy "PixelCart customer discount details read" on public.pixelcart_discounts
for select to authenticated
using (
  public.pixelcart_is_owner()
  or exists (
    select 1 from public.pixelcart_customer_discounts cd
    where cd.discount_id = pixelcart_discounts.id
      and cd.user_id = auth.uid()
  )
);

-- Keep direct writes to customer discount claims unavailable to clients.
revoke insert, update, delete on public.pixelcart_customer_discounts from anon, authenticated;
grant select on public.pixelcart_customer_discounts to authenticated;
