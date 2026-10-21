-- Met-Cloud checkout: reuses the existing server-side plan/wallet transaction,
-- but requires MetPay password verification and writes both internal Met-Ail receipts
-- in the same database transaction.
create or replace function public.metxon_purchase_cloud_plan_secure(
  p_capacity_gb integer,
  p_metpay_password text,
  p_delivery jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  uid uuid := auth.uid();
  v_hash text;
  v_result jsonb;
  v_username text;
  v_customer_mailbox text;
  v_owner_id uuid;
  v_owner_mailbox text;
  v_order_id text := 'MCL-' || upper(substr(replace(pg_catalog.gen_random_uuid()::text,'-',''),1,12));
  v_receipt text;
  v_charged numeric;
begin
  if uid is null then raise exception 'Sign in first.'; end if;
  if p_metpay_password is null or length(p_metpay_password)=0 or length(p_metpay_password)>128 then
    raise exception 'Enter your MetPay transaction password.';
  end if;
  select mp.password_hash into v_hash
    from public.metpay_passwords mp where mp.user_id=uid;
  if v_hash is null or v_hash <> extensions.crypt(p_metpay_password,v_hash) then
    raise exception 'MetPay transaction password is incorrect.';
  end if;

  select pr.username into v_username from public.profiles pr where pr.id=uid;
  select ma.username into v_customer_mailbox
    from public.metail_accounts ma where ma.user_id=uid order by ma.created_at asc limit 1;
  if v_customer_mailbox is null then raise exception 'Create a Met-Ail inbox before purchasing. No payment was taken.'; end if;

  select pr.id into v_owner_id from public.profiles pr
    where pr.role='owner' order by pr.created_at asc limit 1;
  if v_owner_id is null then raise exception 'MetCart owner account is not configured. No payment was taken.'; end if;
  select ma.username into v_owner_mailbox from public.metail_accounts ma
    where ma.user_id=v_owner_id order by ma.created_at asc limit 1;
  if v_owner_mailbox is null then raise exception 'Owner Met-Ail inbox is not configured. No payment was taken.'; end if;

  -- Existing purchase routine locks the wallet and entitlement and applies the price atomically.
  v_result := public.metxon_purchase_cloud_plan(p_capacity_gb);
  if coalesce((v_result->>'ok')::boolean,false) is not true then
    raise exception 'Met-Cloud purchase was not confirmed.';
  end if;
  v_charged := coalesce((v_result->>'charged_jp')::numeric,0);
  if v_charged <= 0 then
    return v_result || jsonb_build_object('already_owned',true,'receipts_saved',false);
  end if;

  v_receipt :=
    'MET-CLOUD PAYMENT RECEIPT' || E'\n' ||
    'Receipt ID: ' || v_order_id || E'\n' ||
    'Purchased at: ' || pg_catalog.to_char(pg_catalog.now() at time zone 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM') || E'\n' ||
    'Customer Metxon account: ' || coalesce(v_username,'') || E'\n' ||
    'Plan: ' || coalesce(v_result->>'plan_name','') || E'\n' ||
    'Capacity: ' || coalesce(v_result->>'capacity_gb','') || ' GB (permanent)' || E'\n' ||
    'Paid: ' || v_charged::text || ' JP (&)' || E'\n' ||
    'Payment method: MetPay / InstaPay' || E'\n' ||
    'Payment status: PAID' || E'\n' ||
    'Optional school details: Class ' || coalesce(nullif(left(p_delivery->>'class',30),''),'not provided') ||
    ', Section ' || coalesce(nullif(left(p_delivery->>'section',20),''),'not provided') ||
    ', Roll number ' || coalesce(nullif(left(p_delivery->>'roll',20),''),'not provided') || E'\n' ||
    'Owner receipt inbox: ' || v_owner_mailbox || '@metail.com';

  insert into public.metmail_messages(owner_id,account_email,folder,sender,recipient,subject,body,is_read)
    values(uid,lower(v_customer_mailbox||'@metail.com'),'Inbox','MetPay',v_customer_mailbox,
      'Met-Cloud receipt — '||v_order_id,v_receipt,false);
  insert into public.metmail_messages(owner_id,account_email,folder,sender,recipient,subject,body,is_read)
    values(v_owner_id,lower(v_owner_mailbox||'@metail.com'),'Inbox','MetPay',
      v_customer_mailbox,'Met-Cloud purchase receipt — '||v_order_id,v_receipt,false);

  return v_result || jsonb_build_object(
    'order_id',v_order_id,'receipt',v_receipt,
    'receipt_email',v_customer_mailbox||'@metail.com',
    'owner_email',v_owner_mailbox||'@metail.com','receipts_saved',true
  );
end;
$function$;

revoke all on function public.metxon_purchase_cloud_plan_secure(integer,text,jsonb) from public, anon;
grant execute on function public.metxon_purchase_cloud_plan_secure(integer,text,jsonb) to authenticated;

-- Prevent callers from bypassing password verification by invoking the legacy
-- one-argument purchase routine directly. The secure wrapper invokes it as owner.
revoke all on function public.metxon_purchase_cloud_plan(integer) from public, anon, authenticated;
