-- Migration: Initial schema for Nova Era Express laundry delivery system
-- Run via Supabase CLI:  supabase migrations new init_schema && replace the generated .sql with this file

-- Extensions -----------------------------------------------------------------
create extension if not exists "uuid-ossp";

-- Tables ----------------------------------------------------------------------

-- 1. Customers ----------------------------------------------------------------
create table public.customers (
  id              uuid primary key default uuid_generate_v4(),
  auth_user_id    uuid not null references auth.users(id) on delete cascade,
  full_name       text not null,
  email           text not null unique,
  phone           text,
  address         jsonb,                    -- {street, number, city, state, zip}
  created_at      timestamptz not null default now()
);

-- 2. Orders -------------------------------------------------------------------
create table public.orders (
  id               bigint generated always as identity primary key,
  customer_id      uuid not null references public.customers(id) on delete cascade,
  pickup_eta       timestamptz,            -- when courier should arrive to pick up dirty clothes
  dropoff_eta      timestamptz,            -- when courier should return clean clothes
  special_notes    text,
  status           text not null default 'pending' check (
                     status in ('pending','scheduled','picked_up','washing','ready','delivered','cancelled')
                   ),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- 3. Deliveries ---------------------------------------------------------------
create table public.deliveries (
  id                 bigint generated always as identity primary key,
  order_id           bigint not null references public.orders(id) on delete cascade,
  uber_delivery_id   text unique,        -- returned by Uber Direct API
  estimate_id        text,
  direction          text not null check (direction in ('pickup','return')),  -- pickup = client→lavanderia, return = lavanderia→client
  price              numeric(10,2),
  current_status     text,               -- last status received from webhook
  courier_name       text,
  courier_phone      text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- 4. Delivery status events ---------------------------------------------------
create table public.delivery_status_events (
  id              bigint generated always as identity primary key,
  delivery_id     bigint not null references public.deliveries(id) on delete cascade,
  status          text not null,          -- e.g. accepted, en_route_to_pickup, delivered
  raw_payload     jsonb,                  -- entire webhook payload for debugging/audit
  event_time      timestamptz not null default now()
);

-- Helpers ---------------------------------------------------------------------

-- Trigger function to auto‑update updated_at columns
create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin
  NEW.updated_at := now();
  return NEW;
end$$;

create trigger trg_orders_updated
  before update on public.orders
  for each row execute procedure public.set_updated_at();

create trigger trg_deliveries_updated
  before update on public.deliveries
  for each row execute procedure public.set_updated_at();

-- Row‑Level Security ----------------------------------------------------------

alter table public.customers enable row level security;
alter table public.orders enable row level security;
alter table public.deliveries enable row level security;
alter table public.delivery_status_events enable row level security;

-- Customers: each user can read/update only their own customer profile
create policy "Customers: owner can read" on public.customers
  for select using (auth.uid() = auth_user_id);
create policy "Customers: owner can update" on public.customers
  for update using (auth.uid() = auth_user_id);

-- Orders: customer owns row via customer_id relationship
create policy "Orders: owner can read" on public.orders
  for select using (
    auth.uid() = (select auth_user_id from public.customers where id = customer_id)
  );
create policy "Orders: owner can insert" on public.orders
  for insert with check (
    auth.uid() = (select auth_user_id from public.customers where id = customer_id)
  );
create policy "Orders: owner can update" on public.orders
  for update using (
    auth.uid() = (select auth_user_id from public.customers where id = customer_id)
  );

-- Deliveries: ownership via order relationship
create policy "Deliveries: owner can read" on public.deliveries
  for select using (
    auth.uid() = (
      select auth_user_id from public.customers c
      join public.orders o on o.customer_id = c.id
      where o.id = order_id
    )
  );

-- Delivery Status Events are read‑only by owners
create policy "Events: owner can read" on public.delivery_status_events
  for select using (
    auth.uid() = (
      select auth_user_id from public.customers c
      join public.orders o on o.customer_id = c.id
      join public.deliveries d on d.order_id = o.id
      where d.id = delivery_id
    )
  );

-- Done -----------------------------------------------------------------------
