-- Shared MetPay saved-contact display and secure Mettin purchase lookup.
-- Contacts are returned only to their owner; this avoids exposing all profile usernames
-- through a broad profiles SELECT policy.
create or replace function public.metpay_get_contacts_with_usernames()
returns table(contact_id uuid, username text, display_name text, created_at timestamptz)
language sql
security definer
set search_path = public, pg_temp
as $function$
  select c.contact_id, p.username, p.display_name, c.created_at
  from public.metpay_contacts c
  join public.profiles p on p.id = c.contact_id
  where c.user_id = auth.uid()
  order by c.created_at desc;
$function$;

revoke all on function public.metpay_get_contacts_with_usernames() from public, anon;
grant execute on function public.metpay_get_contacts_with_usernames() to authenticated;

-- MetCart orders currently have RLS enabled without a customer SELECT policy.
-- Return only the signed-in customer's own order items for Mettin's purchase gate.
create or replace function public.mettin_get_my_metcart_orders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  u uuid := auth.uid();
  result jsonb;
begin
  if u is null then
    raise exception 'Sign in to Metxon before checking SME purchases.';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'items', o.items,
    'status', o.status,
    'created_at', o.created_at
  ) order by o.created_at desc), '[]'::jsonb)
  into result
  from public.metcart_orders o
  where o.user_id = u;
  return result;
end;
$function$;

revoke all on function public.mettin_get_my_metcart_orders() from public, anon;
grant execute on function public.mettin_get_my_metcart_orders() to authenticated;
