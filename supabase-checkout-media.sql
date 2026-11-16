-- PixelCart cloud checkout, permissions, and product media
-- Run AFTER supabase-setup.sql in the Supabase SQL Editor.

-- API roles need table privileges in addition to RLS policies.
grant select on public.pixelcart_categories, public.pixelcart_products,
  public.pixelcart_delivery_fees, public.pixelcart_store_settings,
  public.pixelcart_reviews to anon, authenticated;
grant insert, update, delete on public.pixelcart_categories,
  public.pixelcart_products, public.pixelcart_delivery_fees,
  public.pixelcart_store_settings to authenticated;
grant insert on public.pixelcart_reviews to authenticated;
grant update, delete on public.pixelcart_reviews to authenticated;
grant select on public.pixelcart_orders to authenticated;
grant update, delete on public.pixelcart_orders to authenticated;
grant select, insert, update, delete on public.pixelcart_discounts to authenticated;
grant select on public.pixelcart_customer_discounts to authenticated;

-- Orders must be created through the validated function, not direct client inserts.
drop policy if exists "PixelCart customer order insert" on public.pixelcart_orders;
revoke insert on public.pixelcart_orders from anon, authenticated;

create or replace function public.pixelcart_place_order(p_order jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_product public.pixelcart_products%rowtype;
  v_options jsonb;
  v_option jsonb;
  v_variant_index integer;
  v_qty integer;
  v_price numeric;
  v_subtotal numeric := 0;
  v_fee numeric := 0;
  v_country text;
  v_name text;
  v_phone text;
  v_address text;
  v_city text;
  v_items jsonb := '[]'::jsonb;
  v_order_id text;
  v_order jsonb;
  v_stock integer;
begin
  if coalesce(jsonb_typeof(p_order),'null') <> 'object' then
    raise exception 'Invalid order details.';
  end if;

  v_name := btrim(coalesce(p_order->>'name',''));
  v_phone := btrim(coalesce(p_order->>'phone',''));
  v_address := btrim(coalesce(p_order->>'address',''));
  v_country := btrim(coalesce(p_order->>'country',''));
  v_city := btrim(coalesce(p_order->>'city',''));

  if v_name = '' or length(v_name) > 120 then
    raise exception 'A valid full name is required.';
  end if;
  if v_phone = '' or length(v_phone) > 40 then
    raise exception 'A valid phone number is required.';
  end if;
  if v_address = '' or length(v_address) > 1000 then
    raise exception 'A delivery address is required.';
  end if;
  if v_country = '' then
    raise exception 'Choose a delivery country.';
  end if;
  if jsonb_typeof(p_order->'items') <> 'array'
     or jsonb_array_length(p_order->'items') < 1
     or jsonb_array_length(p_order->'items') > 50 then
    raise exception 'The cart is empty or contains too many items.';
  end if;

  select fee into v_fee
  from public.pixelcart_delivery_fees where country = v_country;
  if not found then
    raise exception 'Delivery is not configured for this country.';
  end if;
  v_fee := coalesce(v_fee,0);

  for v_item in select value from jsonb_array_elements(p_order->'items')
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Invalid cart item.';
    end if;
    if coalesce(v_item->>'id','') = '' then
      raise exception 'A cart item is missing its product ID.';
    end if;
    if coalesce(v_item->>'qty','') !~ '^[0-9]{1,2}$' then
      raise exception 'Invalid item quantity.';
    end if;
    v_qty := (v_item->>'qty')::integer;
    if v_qty < 1 or v_qty > 50 then
      raise exception 'Invalid item quantity.';
    end if;

    select * into v_product
    from public.pixelcart_products
    where id = v_item->>'id'
    for update;

    if not found then
      raise exception 'A product in your cart is no longer available.';
    end if;

    v_options := coalesce(v_product.data->'options','[]'::jsonb);
    if jsonb_typeof(v_options) <> 'array' then
      raise exception 'Product options are not configured correctly.';
    end if;
    if coalesce(v_item->>'variantIndex','-1') !~ '^-?[0-9]{1,3}$' then
      raise exception 'Choose a valid product option.';
    end if;
    v_variant_index := coalesce((v_item->>'variantIndex')::integer,-1);

    if jsonb_array_length(v_options) > 0 then
      if v_variant_index < 0 or v_variant_index >= jsonb_array_length(v_options) then
        raise exception 'Choose a valid product option.';
      end if;
      v_option := v_options->v_variant_index;
      v_stock := coalesce((v_option->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_option->>'price')::numeric,(v_product.data->>'price')::numeric,0);
      v_option := jsonb_set(v_option,'{stock}',to_jsonb(v_stock-v_qty),true);
      v_options := jsonb_set(v_options,array[v_variant_index::text],v_option,true);
      v_stock := 0;
      for v_option in select value from jsonb_array_elements(v_options)
      loop v_stock := v_stock + coalesce((v_option->>'stock')::integer,0); end loop;
      update public.pixelcart_products
      set data = jsonb_set(jsonb_set(data,'{options}',v_options,true),'{stock}',to_jsonb(v_stock),true),
          updated_at = now()
      where id = v_product.id;
      v_option := v_options->v_variant_index;
    else
      v_stock := coalesce((v_product.data->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_product.data->>'price')::numeric,0);
      update public.pixelcart_products
      set data = jsonb_set(data,'{stock}',to_jsonb(v_stock-v_qty),true),
          updated_at = now()
      where id = v_product.id;
    end if;

    v_subtotal := v_subtotal + (v_price * v_qty);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id',v_product.id,
      'name',v_product.data->>'name',
      'number',v_product.data->>'number',
      'qty',v_qty,
      'price',v_price,
      'variantIndex',v_variant_index,
      'label',coalesce(v_item->>'label','')
    ));
  end loop;

  v_order_id := 'ORD-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  v_order := jsonb_build_object(
    'id',v_order_id,'name',v_name,'phone',v_phone,'address',v_address,
    'country',v_country,'city',v_city,'items',v_items,
    'subtotal',v_subtotal,'fee',v_fee,'total',v_subtotal+v_fee,
    'status','New','date',to_char(now(),'YYYY-MM-DD HH24:MI:SS')
  );

  insert into public.pixelcart_orders(id,customer_id,data)
  values(v_order_id,auth.uid(),v_order);

  return v_order;
end;
$$;

revoke all on function public.pixelcart_place_order(jsonb) from public;
grant execute on function public.pixelcart_place_order(jsonb) to anon, authenticated;

-- Public product images/videos are readable; only the store owner can upload,
-- replace, or delete media. Do not store customer/private files in this bucket.
insert into storage.buckets(id,name,public)
values('pixelcart-product-media','pixelcart-product-media',true)
on conflict (id) do update set public = true;

drop policy if exists "PixelCart product media public read" on storage.objects;
create policy "PixelCart product media public read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'pixelcart-product-media');

drop policy if exists "PixelCart product media owner insert" on storage.objects;
create policy "PixelCart product media owner insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner update" on storage.objects;
create policy "PixelCart product media owner update"
on storage.objects for update to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner())
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner delete" on storage.objects;
create policy "PixelCart product media owner delete"
on storage.objects for delete to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());
 then
      raise exception 'Invalid cart item or quantity.';
    end if;
    v_qty := (v_item->>'qty')::integer;
    if v_qty < 1 or v_qty > 50 then
      raise exception 'Invalid item quantity.';
    end if;

    select * into v_product
    from public.pixelcart_products
    where id = v_item->>'id'
    for update;

    if not found then
      raise exception 'A product in your cart is no longer available.';
    end if;

    v_options := coalesce(v_product.data->'options','[]'::jsonb);
    v_variant_index := coalesce((v_item->>'variantIndex')::integer,-1);

    if jsonb_array_length(v_options) > 0 then
      if v_variant_index < 0 or v_variant_index >= jsonb_array_length(v_options) then
        raise exception 'Choose a valid product option.';
      end if;
      v_option := v_options->v_variant_index;
      v_stock := coalesce((v_option->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_option->>'price')::numeric,(v_product.data->>'price')::numeric,0);
      v_option := jsonb_set(v_option,'{stock}',to_jsonb(v_stock-v_qty),true);
      v_options := jsonb_set(v_options,array[v_variant_index::text],v_option,true);
      v_stock := 0;
      for v_option in select value from jsonb_array_elements(v_options)
      loop v_stock := v_stock + coalesce((v_option->>'stock')::integer,0); end loop;
      update public.pixelcart_products
      set data = jsonb_set(jsonb_set(data,'{options}',v_options,true),'{stock}',to_jsonb(v_stock),true),
          updated_at = now()
      where id = v_product.id;
      v_option := v_options->v_variant_index;
    else
      v_stock := coalesce((v_product.data->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_product.data->>'price')::numeric,0);
      update public.pixelcart_products
      set data = jsonb_set(data,'{stock}',to_jsonb(v_stock-v_qty),true),
          updated_at = now()
      where id = v_product.id;
    end if;

    v_subtotal := v_subtotal + (v_price * v_qty);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id',v_product.id,
      'name',v_product.data->>'name',
      'number',v_product.data->>'number',
      'qty',v_qty,
      'price',v_price,
      'variantIndex',v_variant_index,
      'label',coalesce(v_item->>'label','')
    ));
  end loop;

  v_order_id := 'ORD-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  v_order := jsonb_build_object(
    'id',v_order_id,'name',v_name,'phone',v_phone,'address',v_address,
    'country',v_country,'city',v_city,'items',v_items,
    'subtotal',v_subtotal,'fee',v_fee,'total',v_subtotal+v_fee,
    'status','New','date',to_char(now(),'YYYY-MM-DD HH24:MI:SS')
  );

  insert into public.pixelcart_orders(id,customer_id,data)
  values(v_order_id,auth.uid(),v_order);

  return v_order;
end;
$$;

revoke all on function public.pixelcart_place_order(jsonb) from public;
grant execute on function public.pixelcart_place_order(jsonb) to anon, authenticated;

-- Public product images/videos are readable; only the store owner can upload,
-- replace, or delete media. Do not store customer/private files in this bucket.
insert into storage.buckets(id,name,public)
values('pixelcart-product-media','pixelcart-product-media',true)
on conflict (id) do update set public = true;

drop policy if exists "PixelCart product media public read" on storage.objects;
create policy "PixelCart product media public read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'pixelcart-product-media');

drop policy if exists "PixelCart product media owner insert" on storage.objects;
create policy "PixelCart product media owner insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner update" on storage.objects;
create policy "PixelCart product media owner update"
on storage.objects for update to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner())
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner delete" on storage.objects;
create policy "PixelCart product media owner delete"
on storage.objects for delete to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());
 then
      raise exception 'Choose a valid product option.';
    end if;
    v_variant_index := coalesce((v_item->>'variantIndex')::integer,-1);

    if jsonb_array_length(v_options) > 0 then
      if v_variant_index < 0 or v_variant_index >= jsonb_array_length(v_options) then
        raise exception 'Choose a valid product option.';
      end if;
      v_option := v_options->v_variant_index;
      v_stock := coalesce((v_option->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_option->>'price')::numeric,(v_product.data->>'price')::numeric,0);
      v_option := jsonb_set(v_option,'{stock}',to_jsonb(v_stock-v_qty),true);
      v_options := jsonb_set(v_options,array[v_variant_index::text],v_option,true);
      v_stock := 0;
      for v_option in select value from jsonb_array_elements(v_options)
      loop v_stock := v_stock + coalesce((v_option->>'stock')::integer,0); end loop;
      update public.pixelcart_products
      set data = jsonb_set(jsonb_set(data,'{options}',v_options,true),'{stock}',to_jsonb(v_stock),true),
          updated_at = now()
      where id = v_product.id;
      v_option := v_options->v_variant_index;
    else
      v_stock := coalesce((v_product.data->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_product.data->>'price')::numeric,0);
      update public.pixelcart_products
      set data = jsonb_set(data,'{stock}',to_jsonb(v_stock-v_qty),true),
          updated_at = now()
      where id = v_product.id;
    end if;

    v_subtotal := v_subtotal + (v_price * v_qty);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id',v_product.id,
      'name',v_product.data->>'name',
      'number',v_product.data->>'number',
      'qty',v_qty,
      'price',v_price,
      'variantIndex',v_variant_index,
      'label',coalesce(v_item->>'label','')
    ));
  end loop;

  v_order_id := 'ORD-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  v_order := jsonb_build_object(
    'id',v_order_id,'name',v_name,'phone',v_phone,'address',v_address,
    'country',v_country,'city',v_city,'items',v_items,
    'subtotal',v_subtotal,'fee',v_fee,'total',v_subtotal+v_fee,
    'status','New','date',to_char(now(),'YYYY-MM-DD HH24:MI:SS')
  );

  insert into public.pixelcart_orders(id,customer_id,data)
  values(v_order_id,auth.uid(),v_order);

  return v_order;
end;
$$;

revoke all on function public.pixelcart_place_order(jsonb) from public;
grant execute on function public.pixelcart_place_order(jsonb) to anon, authenticated;

-- Public product images/videos are readable; only the store owner can upload,
-- replace, or delete media. Do not store customer/private files in this bucket.
insert into storage.buckets(id,name,public)
values('pixelcart-product-media','pixelcart-product-media',true)
on conflict (id) do update set public = true;

drop policy if exists "PixelCart product media public read" on storage.objects;
create policy "PixelCart product media public read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'pixelcart-product-media');

drop policy if exists "PixelCart product media owner insert" on storage.objects;
create policy "PixelCart product media owner insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner update" on storage.objects;
create policy "PixelCart product media owner update"
on storage.objects for update to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner())
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner delete" on storage.objects;
create policy "PixelCart product media owner delete"
on storage.objects for delete to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());
 then
      raise exception 'Invalid cart item or quantity.';
    end if;
    v_qty := (v_item->>'qty')::integer;
    if v_qty < 1 or v_qty > 50 then
      raise exception 'Invalid item quantity.';
    end if;

    select * into v_product
    from public.pixelcart_products
    where id = v_item->>'id'
    for update;

    if not found then
      raise exception 'A product in your cart is no longer available.';
    end if;

    v_options := coalesce(v_product.data->'options','[]'::jsonb);
    v_variant_index := coalesce((v_item->>'variantIndex')::integer,-1);

    if jsonb_array_length(v_options) > 0 then
      if v_variant_index < 0 or v_variant_index >= jsonb_array_length(v_options) then
        raise exception 'Choose a valid product option.';
      end if;
      v_option := v_options->v_variant_index;
      v_stock := coalesce((v_option->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_option->>'price')::numeric,(v_product.data->>'price')::numeric,0);
      v_option := jsonb_set(v_option,'{stock}',to_jsonb(v_stock-v_qty),true);
      v_options := jsonb_set(v_options,array[v_variant_index::text],v_option,true);
      v_stock := 0;
      for v_option in select value from jsonb_array_elements(v_options)
      loop v_stock := v_stock + coalesce((v_option->>'stock')::integer,0); end loop;
      update public.pixelcart_products
      set data = jsonb_set(jsonb_set(data,'{options}',v_options,true),'{stock}',to_jsonb(v_stock),true),
          updated_at = now()
      where id = v_product.id;
      v_option := v_options->v_variant_index;
    else
      v_stock := coalesce((v_product.data->>'stock')::integer,0);
      if v_stock < v_qty then raise exception 'Not enough stock for %.', v_product.data->>'name'; end if;
      v_price := coalesce((v_product.data->>'price')::numeric,0);
      update public.pixelcart_products
      set data = jsonb_set(data,'{stock}',to_jsonb(v_stock-v_qty),true),
          updated_at = now()
      where id = v_product.id;
    end if;

    v_subtotal := v_subtotal + (v_price * v_qty);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id',v_product.id,
      'name',v_product.data->>'name',
      'number',v_product.data->>'number',
      'qty',v_qty,
      'price',v_price,
      'variantIndex',v_variant_index,
      'label',coalesce(v_item->>'label','')
    ));
  end loop;

  v_order_id := 'ORD-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  v_order := jsonb_build_object(
    'id',v_order_id,'name',v_name,'phone',v_phone,'address',v_address,
    'country',v_country,'city',v_city,'items',v_items,
    'subtotal',v_subtotal,'fee',v_fee,'total',v_subtotal+v_fee,
    'status','New','date',to_char(now(),'YYYY-MM-DD HH24:MI:SS')
  );

  insert into public.pixelcart_orders(id,customer_id,data)
  values(v_order_id,auth.uid(),v_order);

  return v_order;
end;
$$;

revoke all on function public.pixelcart_place_order(jsonb) from public;
grant execute on function public.pixelcart_place_order(jsonb) to anon, authenticated;

-- Public product images/videos are readable; only the store owner can upload,
-- replace, or delete media. Do not store customer/private files in this bucket.
insert into storage.buckets(id,name,public)
values('pixelcart-product-media','pixelcart-product-media',true)
on conflict (id) do update set public = true;

drop policy if exists "PixelCart product media public read" on storage.objects;
create policy "PixelCart product media public read"
on storage.objects for select to anon, authenticated
using (bucket_id = 'pixelcart-product-media');

drop policy if exists "PixelCart product media owner insert" on storage.objects;
create policy "PixelCart product media owner insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner update" on storage.objects;
create policy "PixelCart product media owner update"
on storage.objects for update to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner())
with check (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());

drop policy if exists "PixelCart product media owner delete" on storage.objects;
create policy "PixelCart product media owner delete"
on storage.objects for delete to authenticated
using (bucket_id = 'pixelcart-product-media' and public.pixelcart_is_owner());
