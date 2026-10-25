-- Metxon Care+ and Care Ultra subscriptions.
-- Listed price is INR 500,000. The existing wallet rate is INR 100 per JP,
-- so the secure purchase function debits 5,000 JP.
create table if not exists public.metxon_care_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_code text not null check (plan_code in ('care_plus','care_ultra')),
  price numeric(14,2) not null check (price = 500000),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint metxon_care_subscriptions_valid_period check (expires_at > started_at)
);
create index if not exists metxon_care_subscriptions_user_active_idx
  on public.metxon_care_subscriptions (user_id, expires_at desc);
alter table public.metxon_care_subscriptions enable row level security;
revoke all on table public.metxon_care_subscriptions from anon, authenticated;
grant select on table public.metxon_care_subscriptions to authenticated;
drop policy if exists metxon_care_subscriptions_select_own on public.metxon_care_subscriptions;
create policy metxon_care_subscriptions_select_own
on public.metxon_care_subscriptions for select to authenticated
using ((select auth.uid()) = user_id);
drop policy if exists metxon_care_subscriptions_support_read on public.metxon_care_subscriptions;
create policy metxon_care_subscriptions_support_read
on public.metxon_care_subscriptions for select to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = (select auth.uid()) and p.role in ('owner','admin')
));
create or replace function public.metxon_buy_care_plan(p_plan_code text, p_plan_price numeric)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_plan text := lower(trim(coalesce(p_plan_code,'')));
  v_canonical_price numeric(14,2) := 500000;
  v_start timestamptz;
  v_expiry timestamptz;
  v_debit numeric(14,2) := 5000;
begin
  if v_uid is null then raise exception 'Sign in to buy Metxon Care.'; end if;
  if v_plan not in ('care_plus','care_ultra') then raise exception 'Invalid Metxon Care plan.'; end if;
  if p_plan_price is null or p_plan_price <> v_canonical_price then raise exception 'Care plan price changed. Refresh and try again.'; end if;
  select * into v_profile from public.profiles where id = v_uid for update;
  if not found then raise exception 'Your Metxon profile was not found.'; end if;
  if coalesce(v_profile.jp_balance,0) < v_debit then raise exception 'Insufficient InstaPay balance. Required: π5,000 JP.'; end if;
  select greatest(now(), coalesce(max(expires_at) filter (where expires_at > now()), now()))
    into v_start from public.metxon_care_subscriptions where user_id = v_uid and plan_code = v_plan;
  if v_plan = 'care_plus' then v_expiry := v_start + interval '3 months';
  else v_expiry := v_start + interval '1 month'; end if;
  update public.profiles set jp_balance = jp_balance - v_debit, updated_at = now() where id = v_uid;
  insert into public.metxon_care_subscriptions(user_id, plan_code, price, started_at, expires_at)
  values (v_uid, v_plan, v_canonical_price, v_start, v_expiry);
  insert into public.transactions(user_id, type, amount, note)
  values (v_uid, 'Metxon Care (InstaPay)', -v_debit,
    case when v_plan = 'care_plus' then 'Metxon Care+ subscription, 3 months; listed price ₹500000'
         else 'Metxon Care Ultra subscription, 1 month; listed price ₹500000' end);
  insert into public.metxon_jp_transactions(user_id, amount, transaction_type, note)
  values (v_uid, -v_debit, 'debit',
    case when v_plan = 'care_plus' then 'Metxon Care+ renewal (3 months)'
         else 'Metxon Care Ultra renewal (1 month)' end);
  return jsonb_build_object('success',true,'plan_code',v_plan,'price_inr',v_canonical_price,'debited_jp',v_debit,'started_at',v_start,'expires_at',v_expiry);
end;
$function$;
revoke all on function public.metxon_buy_care_plan(text,numeric) from public;
revoke all on function public.metxon_buy_care_plan(text,numeric) from anon;
grant execute on function public.metxon_buy_care_plan(text,numeric) to authenticated;
