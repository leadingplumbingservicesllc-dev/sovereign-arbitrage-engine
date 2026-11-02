begin;
insert into public.execution_metrics(chain_id,contract_address,route_id,success,latency_ms,slippage_bps,created_at)
values (8453,'0x1111111111111111111111111111111111111111','expired',false,5,1,clock_timestamp()-interval '61 seconds');
insert into public.execution_metrics(chain_id,contract_address,route_id,success,latency_ms,slippage_bps)
select 8453,'0x1111111111111111111111111111111111111111','active',false,5,10 from generate_series(1,3);
do $$ begin
 if not exists(select 1 from public.learning_state_cache where route_id='active' and samples=3 and blocked_until>clock_timestamp()) then raise exception 'Failure breaker not activated'; end if;
 if not exists(select 1 from public.execution_metrics where route_id='active' and repeated_failure) then raise exception 'Failure flag missing'; end if;
 if exists(select 1 from public.learning_state_cache where route_id='expired' and blocked_until is not null) then raise exception 'Expired failure counted'; end if;
end $$;
rollback;
