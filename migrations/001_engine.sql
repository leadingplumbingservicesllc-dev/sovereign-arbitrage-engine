begin;
create table public.rwa_arbitrage_triggers (
 id bigint generated always as identity primary key,
 chain_id bigint not null check (chain_id in (8453,42161)),
 contract_address text not null check (contract_address ~ '^0x[0-9a-fA-F]{40}$'),
 route_id text not null,
 created_at timestamptz not null default clock_timestamp(),
 expected_profit numeric(78,0) not null,
 nav_delta_bps double precision not null,
 unique (chain_id, route_id, created_at)
);
create table public.execution_metrics (
 id bigint generated always as identity primary key,
 chain_id bigint not null check (chain_id in (8453,42161)),
 contract_address text not null check (contract_address ~ '^0x[0-9a-fA-F]{40}$'),
 route_id text not null,
 tx_hash text unique check (tx_hash is null or tx_hash ~ '^0x[0-9a-fA-F]{64}$'),
 created_at timestamptz not null default clock_timestamp(),
 success boolean not null,
 latency_ms double precision not null check (latency_ms >= 0),
 slippage_bps double precision not null,
 gas_used numeric(78,0),
 error text,
 repeated_failure boolean not null default false
);
create table public.learning_state_cache (
 chain_id bigint not null check (chain_id in (8453,42161)),
 route_id text not null,
 failure_ema double precision not null default 0 check (failure_ema between 0 and 1),
 slippage_ema_bps double precision not null default 0,
 latency_ema_ms double precision not null default 0,
 samples bigint not null default 0,
 blocked_until timestamptz,
 updated_at timestamptz not null default clock_timestamp(),
 primary key (chain_id,route_id)
);
create index metrics_route_time on public.execution_metrics(chain_id,route_id,created_at desc) include (success,slippage_bps,latency_ms);
create index metrics_failures on public.execution_metrics(chain_id,route_id,created_at desc) where not success;
create index metrics_contract on public.execution_metrics(chain_id,contract_address,created_at desc);
create index metrics_latency on public.execution_metrics(latency_ms);
create index metrics_slippage on public.execution_metrics(slippage_bps);
create index triggers_contract_time on public.rwa_arbitrage_triggers(chain_id,contract_address,created_at desc);
create index metrics_time_brin on public.execution_metrics using brin(created_at);
create function public.update_learning() returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare failures bigint;
begin
 -- Serialize updates for the route so concurrent writers cannot lose learning samples.
 perform pg_advisory_xact_lock(hashtextextended(new.chain_id::text || ':' || new.route_id,0));
 insert into public.learning_state_cache(chain_id,route_id,failure_ema,slippage_ema_bps,latency_ema_ms,samples)
 values(new.chain_id,new.route_id,case when new.success then 0 else 1 end, greatest(0,new.slippage_bps),new.latency_ms,1)
 on conflict(chain_id,route_id) do update set
 failure_ema = 0.9 * learning_state_cache.failure_ema + 0.1 * excluded.failure_ema,
 slippage_ema_bps = 0.9 * learning_state_cache.slippage_ema_bps + 0.1 * excluded.slippage_ema_bps,
 latency_ema_ms = 0.9 * learning_state_cache.latency_ema_ms + 0.1 * excluded.latency_ema_ms,
 samples = learning_state_cache.samples + 1, updated_at = clock_timestamp();
 select count(*) into failures from public.execution_metrics
 where chain_id=new.chain_id and route_id=new.route_id and not success
 and created_at >= clock_timestamp() - interval '60 seconds';
 if failures >= 3 then
 new.repeated_failure := true;
 update public.learning_state_cache set blocked_until=clock_timestamp()+interval '60 seconds'
 where chain_id=new.chain_id and route_id=new.route_id;
 end if;
 return new;
end $$;
-- AFTER sees the inserted row; update only the flag, avoiding recursive INSERT triggers.
create function public.flag_failures() returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
 if exists(select 1 from public.learning_state_cache where chain_id=new.chain_id and route_id=new.route_id and blocked_until>clock_timestamp()) then
 update public.execution_metrics set repeated_failure=true where id=new.id;
 end if;
 return null;
end $$;
-- AFTER INSERT includes the current execution in the rolling count.
create trigger learn_execution after insert on public.execution_metrics for each row execute function public.update_learning();
create trigger z_flag_execution after insert on public.execution_metrics for each row execute function public.flag_failures();
alter table public.rwa_arbitrage_triggers enable row level security;
alter table public.execution_metrics enable row level security;
alter table public.learning_state_cache enable row level security;
revoke all on public.rwa_arbitrage_triggers,public.execution_metrics,public.learning_state_cache from anon,authenticated;
grant select,insert on public.rwa_arbitrage_triggers,public.execution_metrics to service_role;
grant select on public.learning_state_cache to service_role;
grant usage,select on sequence public.rwa_arbitrage_triggers_id_seq,public.execution_metrics_id_seq to service_role;
commit;
