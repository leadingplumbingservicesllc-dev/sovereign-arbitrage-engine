import json
from pathlib import Path

import httpx
import pytest
from jsonschema import ValidationError
from eth_abi import decode

from oracle.engine import Cache, PLAN, adapt, calldata, load_config


def test_risk_increases_margin_and_caps_gas():
    risk = adapt(
        {"failure_ema": 1, "slippage_ema_bps": 75, "latency_ema_ms": 60000},
        20,
        50,
        100,
        200,
    )
    assert risk.margin_bps == 295
    assert risk.slippage_bps == 25
    assert risk.tip_wei == 200


def test_risk_baseline():
    assert adapt({}, 20, 50, 100, 200).margin_bps == 20


def test_payload_roundtrip():
    a, b, dex = "0x" + "01" * 20, "0x" + "02" * 20, "0x" + "03" * 20
    p = (
        a,
        1000,
        10,
        1,
        2000,
        0,
        [(dex, a, b, 3000, 1, 900), (dex, b, a, 3000, 1, 1020)],
    )
    data = calldata(f"execute({PLAN})", [PLAN], [p])
    assert decode([PLAN], data[4:])[0][1] == 1000


def test_config_rejects_missing_chain(tmp_path: Path):
    p = tmp_path / "config.json"
    p.write_text(json.dumps([]))
    with pytest.raises(ValidationError):
        load_config(str(p))


def test_cache_http_failure_is_not_empty_learning(monkeypatch):
    import asyncio

    monkeypatch.setenv("SUPABASE_URL", "https://database.supabase.co")
    monkeypatch.setenv("SUPABASE_KEY", "test-only")

    async def run():
        cache = Cache()
        await cache.client.aclose()
        cache.client = httpx.AsyncClient(
            base_url="https://database.supabase.co/rest/v1/",
            transport=httpx.MockTransport(lambda _: httpx.Response(503)),
        )
        try:
            with pytest.raises(httpx.HTTPStatusError):
                await cache.state(8453, "route")
        finally:
            await cache.client.aclose()

    asyncio.run(run())


def test_nonfinite_learning_rejected():
    with pytest.raises(ValueError, match="Non-finite"):
        adapt({"failure_ema": float("nan")}, 20, 50, 100, 200)


@pytest.mark.parametrize(
    "answer,updated,answered",
    [(0, 1000, 1), (100, 1, 1), (100, 1000, 0), (100, 2000, 1)],
)
def test_nav_invalid_rounds_rejected(monkeypatch, answer, updated, answered):
    import asyncio
    from oracle.engine import Chain

    monkeypatch.setattr("oracle.engine.time.time", lambda: 1000)
    chain = object.__new__(Chain)

    async def call(target, signature, types, values, returns):
        return (
            (8,)
            if signature == "decimals()"
            else (1, answer, updated, updated, answered)
        )

    chain.call = call
    with pytest.raises(ValueError, match="stale NAV"):
        asyncio.run(chain.nav("0x" + "01" * 20, 60))
