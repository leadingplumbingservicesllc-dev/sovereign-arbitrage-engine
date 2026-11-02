"""Block-driven, fail-closed execution with explicit chain and asset configuration."""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import time
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, cast
from urllib.parse import urlsplit

import httpx
import jsonschema
from eth_abi.abi import decode, encode
from web3.types import Wei
from eth_account import Account
from hexbytes import HexBytes
from web3 import AsyncWeb3, WebSocketProvider, Web3
from websockets.asyncio.client import connect
from websockets.legacy.client import WebSocketClientProtocol
from web3.types import TxParams

LOG = logging.getLogger("sovereign")
PLAN = "(address,uint256,uint256,uint256,uint256,uint256,(address,address,address,uint24,uint8,uint256)[])"


def calldata(signature: str, types: list[str], values: list[Any]) -> bytes:
    return bytes(Web3.keccak(text=signature)[:4]) + encode(types, values)


@dataclass(frozen=True)
class Risk:
    margin_bps: int
    slippage_bps: int
    tip_wei: int


def adapt(
    state: dict[str, Any], base_margin: int, base_slip: int, tip: int, cap: int
) -> Risk:
    raw = tuple(
        float(state.get(key, 0))
        for key in ("failure_ema", "slippage_ema_bps", "latency_ema_ms")
    )
    if not all(math.isfinite(v) for v in raw):
        raise ValueError("Non-finite learning state")
    failure = min(1.0, max(0.0, raw[0]))
    slip = min(500.0, max(0.0, raw[1]))
    latency = min(60000.0, max(0.0, raw[2]))
    # Bounded online EWMA policy; no claim of profitable reinforcement learning.
    return Risk(
        min(2000, base_margin + math.ceil(slip + 200 * failure)),
        min(base_slip, max(1, base_slip - math.ceil(failure * base_slip / 2))),
        min(cap, math.ceil(tip * (1 + failure + latency / 60000))),
    )


class Cache:
    def __init__(self) -> None:
        url = os.environ["SUPABASE_URL"]
        if urlsplit(url).scheme != "https":
            raise ValueError("SUPABASE_URL must use HTTPS")
        key = os.environ["SUPABASE_KEY"]
        self.client = httpx.AsyncClient(
            base_url=url.rstrip("/") + "/rest/v1/",
            timeout=10,
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
        )

    async def state(self, chain: int, route: str) -> dict[str, Any]:
        result = await self.client.get(
            "learning_state_cache",
            params={
                "chain_id": f"eq.{chain}",
                "route_id": f"eq.{route}",
                "select": "*",
            },
        )
        result.raise_for_status()
        rows = result.json()
        return cast(dict[str, Any], rows[0]) if rows else {}

    async def insert(self, table: str, row: dict[str, Any]) -> None:
        response = await self.client.post(
            table, json=row, headers={"Prefer": "return=minimal"}
        )
        response.raise_for_status()


class ProxyWebSocketProvider(WebSocketProvider):
    """Use websockets 15 proxy-aware transport; Web3 7 defaults to the legacy client."""

    async def _provider_specific_connect(self) -> None:
        self._ws = cast(
            WebSocketClientProtocol,
            await connect(self.endpoint_uri, **self.websocket_kwargs),
        )


class Chain:
    def __init__(self, config: dict[str, Any], endpoint: str, cache: Cache) -> None:
        self.c = config
        self.endpoint = endpoint
        if urlsplit(endpoint).scheme != "wss":
            raise ValueError("Private RPC endpoints must use wss")
        self.cache = cache
        self.chain_id = int(config["chain_id"])
        if self.chain_id not in (8453, 42161):
            raise ValueError("Unsupported chain")
        self.account = Account.from_key(os.environ["EXECUTION_WALLET_KEY"])
        self.live = os.environ.get("LIVE_TRADING", "false") == "true"
        self.w3: AsyncWeb3[WebSocketProvider]
        self.rpc_lock = asyncio.Lock()

    async def call(
        self,
        target: str,
        signature: str,
        types: list[str],
        values: list[Any],
        returns: list[str],
    ) -> tuple[Any, ...]:
        async with self.rpc_lock:
            raw = await self.w3.eth.call(
                {
                    "to": Web3.to_checksum_address(target),
                    "data": HexBytes(calldata(signature, types, values)),
                }
            )
        return decode(returns, raw)

    async def nav(self, feed: str, age: int) -> Decimal:
        decimals = int((await self.call(feed, "decimals()", [], [], ["uint8"]))[0])
        round_id, answer, _, updated, answered = await self.call(
            feed,
            "latestRoundData()",
            [],
            [],
            ["uint80", "int256", "uint256", "uint256", "uint80"],
        )
        if answer <= 0 or answered < round_id or not 0 <= time.time() - updated <= age:
            raise ValueError("Invalid or stale NAV feed")
        return Decimal(answer) / Decimal(10**decimals)

    async def quote(self, leg: dict[str, Any], amount: int) -> int:
        # Uniswap Quoter V1 and Camelot Algebra V1 quoters use distinct signatures.
        if leg["kind"] == 1:
            sig, types, args = (
                "quoteExactInputSingle(address,address,uint24,uint256,uint160)",
                ["address", "address", "uint24", "uint256", "uint160"],
                [leg["token_in"], leg["token_out"], leg["fee"], amount, 0],
            )
        else:
            sig, types, args = (
                "quoteExactInputSingle(address,address,uint256,uint160)",
                ["address", "address", "uint256", "uint160"],
                [leg["token_in"], leg["token_out"], amount, 0],
            )
        return int((await self.call(leg["quoter"], sig, types, args, ["uint256"]))[0])

    async def evaluate(self, route: dict[str, Any]) -> None:
        started = time.monotonic()
        state = await self.cache.state(self.chain_id, route["id"])
        if (
            state.get("blocked_until")
            and datetime.fromisoformat(state["blocked_until"]).timestamp() > time.time()
        ):
            return
        risk = adapt(
            state,
            int(route["min_margin_bps"]),
            int(route["slippage_bps"]),
            int(self.c["tip_wei"]),
            int(self.c["max_tip_wei"]),
        )
        amount = int(route["amount"])
        legs = route["legs"]
        quotes: list[int] = []
        current = amount
        for leg in legs:
            current = await self.quote(leg, current)
            quotes.append(current)
        loan_nav, rwa_nav = await asyncio.gather(
            self.nav(route["loan_usd_feed"], route["feed_max_age"]),
            self.nav(route["rwa_nav_feed"], route["feed_max_age"]),
        )
        implied = (
            Decimal(amount)
            / Decimal(10 ** route["loan_decimals"])
            * loan_nav
            / (Decimal(quotes[0]) / Decimal(10 ** route["rwa_decimals"]))
        )
        nav_delta = (rwa_nav - implied) * 10000 / rwa_nav
        if nav_delta < Decimal(route["min_nav_discount_bps"]):
            return
        premium_bps = int(
            (
                await self.call(
                    self.c["pool"], "FLASHLOAN_PREMIUM_TOTAL()", [], [], ["uint128"]
                )
            )[0]
        )
        premium = (amount * premium_bps + 9999) // 10000
        if premium_bps > int(self.c["max_premium_bps"]):
            raise ValueError("Premium exceeds configured ceiling")
        nonce = int(
            (await self.call(self.c["router"], "nonce()", [], [], ["uint256"]))[0]
        )
        minimum = max(1, (amount * risk.margin_bps + 9999) // 10000)
        if current < amount + premium + minimum:
            return
        # Requote with the conservative previous-leg output; each hop then has its own bound.
        encoded_legs: list[tuple[Any, ...]] = []
        conservative = amount
        for leg in legs:
            bound = (
                (await self.quote(leg, conservative))
                * (10000 - risk.slippage_bps)
                // 10000
            )
            encoded_legs.append(
                (
                    leg["router"],
                    leg["token_in"],
                    leg["token_out"],
                    leg["fee"],
                    leg["kind"],
                    bound,
                )
            )
            conservative = bound
        head = await self.w3.eth.get_block("latest")
        plan = (
            route["asset"],
            amount,
            minimum,
            premium,
            int(head["timestamp"]) + 60,
            nonce,
            encoded_legs,
        )
        tx: TxParams = {
            "from": self.account.address,
            "to": Web3.to_checksum_address(self.c["router"]),
            "data": HexBytes(calldata(f"execute({PLAN})", [PLAN], [plan])),
            "chainId": self.chain_id,
            "value": Wei(0),
        }
        # A rejected plan returns false without reverting, so gas estimation alone is insufficient.
        result = await self.w3.eth.call(tx)
        if not decode(["bool"], result)[0]:
            raise ValueError("Router rejected plan")
        gas = (await self.w3.eth.estimate_gas(tx)) * 120 // 100
        base_fee = int(head.get("baseFeePerGas", 0))
        max_fee = base_fee * 2 + risk.tip_wei
        if max_fee > int(self.c["max_fee_wei"]):
            return
        # Rollup L1 posting fees are bounded separately by an operator-specified reserve.
        gas_cost = gas * max_fee + int(self.c["l1_fee_reserve_wei"])
        native_nav = await self.nav(self.c["native_usd_feed"], route["feed_max_age"])
        gas_in_loan = int(
            (
                Decimal(gas_cost)
                / Decimal(10**18)
                * native_nav
                / loan_nav
                * Decimal(10 ** route["loan_decimals"])
            ).to_integral_value(rounding="ROUND_CEILING")
        )
        if minimum <= gas_in_loan or gas_cost > int(self.c["max_tx_cost_wei"]):
            return
        await self.cache.insert(
            "rwa_arbitrage_triggers",
            {
                "chain_id": self.chain_id,
                "contract_address": self.c["router"],
                "route_id": route["id"],
                "expected_profit": str(current - amount - premium),
                "nav_delta_bps": float(nav_delta),
            },
        )
        if not self.live:
            LOG.info("simulation passed chain=%s route=%s", self.chain_id, route["id"])
            return
        tx.update(
            {
                "gas": gas,
                "maxFeePerGas": Wei(max_fee),
                "maxPriorityFeePerGas": Wei(risk.tip_wei),
                "nonce": await self.w3.eth.get_transaction_count(
                    self.account.address, "pending"
                ),
            }
        )
        if await self.w3.eth.get_balance(self.account.address) < gas_cost:
            raise ValueError("Execution wallet lacks native gas funds")
        signed = await asyncio.to_thread(self.account.sign_transaction, tx)
        journal = Path(
            os.environ.get("ENGINE_JOURNAL_DIR", "/workspace/engine-journal")
        )
        journal.mkdir(parents=True, exist_ok=True, mode=0o700)
        pending_file = journal / f"{self.chain_id}.json"
        # Exclusive durable intent BEFORE network submission prevents blind retries after a crash.
        with pending_file.open("x") as pending:
            json.dump(
                {
                    "tx_hash": signed.hash.to_0x_hex(),
                    "route_id": route["id"],
                    "nonce": tx["nonce"],
                },
                pending,
            )
            pending.flush()
            os.fsync(pending.fileno())
        tx_hash = await self.w3.eth.send_raw_transaction(signed.raw_transaction)
        # Never resubmit on timeout: stop this chain until the pending transaction is reconciled.
        receipt = await self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
        confirmed_by = time.monotonic() + 180
        while await self.w3.eth.block_number < receipt["blockNumber"] + int(
            self.c["confirmations"]
        ):
            if time.monotonic() > confirmed_by:
                raise TimeoutError("Confirmation deadline exceeded; reconcile journal")
            await asyncio.sleep(1)
        canonical = await self.w3.eth.get_block(receipt["blockNumber"])
        if canonical["hash"] != receipt["blockHash"]:
            raise RuntimeError("Receipt reorged; reconcile journal")
        success = receipt["status"] == 1
        realized_slip = 0.0
        if success:
            topic = Web3.keccak(
                text="Executed(uint256,address,uint256,uint256,uint256)"
            )
            events = [
                log
                for log in receipt["logs"]
                if log["address"].lower() == self.c["router"].lower()
                and log["topics"][0] == topic
            ]
            if len(events) != 1:
                raise RuntimeError(
                    "Mined transaction missing execution event; reconciliation required"
                )
            _, _, profit = decode(["uint256", "uint256", "uint256"], events[0]["data"])
            realized_slip = max(
                0.0, (current - amount - premium - int(profit)) * 10000 / amount
            )
        await self.cache.insert(
            "execution_metrics",
            {
                "chain_id": self.chain_id,
                "contract_address": self.c["router"],
                "route_id": route["id"],
                "tx_hash": tx_hash.to_0x_hex(),
                "success": success,
                "latency_ms": (time.monotonic() - started) * 1000,
                "slippage_bps": realized_slip,
                "gas_used": str(receipt["gasUsed"]),
                "error": None if success else "EVM revert",
            },
        )

        pending_file.unlink()

    async def run(self) -> None:
        if (
            Path(os.environ.get("ENGINE_JOURNAL_DIR", "/workspace/engine-journal"))
            / f"{self.chain_id}.json"
        ).exists():
            raise RuntimeError(
                "Unreconciled transaction journal; reconcile receipt and audit before restart"
            )
        async with AsyncWeb3(ProxyWebSocketProvider(self.endpoint)) as w3:
            self.w3 = w3
            if await w3.eth.chain_id != self.chain_id:
                raise ValueError("RPC chain ID mismatch")
            if not await w3.eth.get_code(Web3.to_checksum_address(self.c["router"])):
                raise ValueError("Router not deployed")
            executor = (
                await self.call(self.c["router"], "executor()", [], [], ["address"])
            )[0]
            if executor.lower() != self.account.address.lower():
                raise ValueError("Execution signer does not match router executor")
            pool = (await self.call(self.c["router"], "pool()", [], [], ["address"]))[0]
            if pool.lower() != self.c["pool"].lower():
                raise ValueError("Configured Aave pool differs from router pool")
            for route in self.c["routes"]:
                for token, expected in [
                    (route["asset"], route["loan_decimals"]),
                    (route["legs"][0]["token_out"], route["rwa_decimals"]),
                ]:
                    actual = (await self.call(token, "decimals()", [], [], ["uint8"]))[
                        0
                    ]
                    if actual != expected:
                        raise ValueError("Configured token decimals mismatch")
            await w3.eth.subscribe("newHeads")
            if self.c.get("subscribe_pending", False):
                await w3.eth.subscribe("newPendingTransactions")
            # Coalesce bursts to bound memory during receipt waits. Sequencer feeds are provider-dependent.
            queue: asyncio.Queue[bool] = asyncio.Queue(maxsize=1)

            async def ingest() -> None:
                async for _ in w3.socket.process_subscriptions():
                    if not queue.full():
                        queue.put_nowait(True)
                raise ConnectionError("RPC subscription closed")

            async with asyncio.TaskGroup() as group:
                group.create_task(ingest())
                while True:
                    await queue.get()
                    for route in self.c["routes"]:
                        await self.evaluate(route)


def load_config(path: str) -> list[dict[str, Any]]:
    configs = cast(list[dict[str, Any]], json.loads(Path(path).read_text()))
    jsonschema.validate(
        configs, json.loads(Path(__file__).with_name("config.schema.json").read_text())
    )
    if {c["chain_id"] for c in configs} != {8453, 42161} or len(configs) != 2:
        raise ValueError("Configure exactly Base and Arbitrum")
    for c in configs:
        if len({r["id"] for r in c["routes"]}) != len(c["routes"]):
            raise ValueError("Route IDs must be unique per chain")
        if not c["routes"] or int(c["l1_fee_reserve_wei"]) <= 0:
            raise ValueError("Routes and positive L1 fee reserve required")
        for r in c["routes"]:
            if (
                len(r["legs"]) != 2
                or r["legs"][0]["token_in"].lower() != r["asset"].lower()
                or r["legs"][1]["token_out"].lower() != r["asset"].lower()
                or r["legs"][0]["token_out"].lower() != r["legs"][1]["token_in"].lower()
            ):
                raise ValueError("Oracle requires two-hop closed routes")
            if not 0 < r["slippage_bps"] <= 100 or not 0 < r["min_margin_bps"] <= 2000:
                raise ValueError("Invalid risk bounds")
    return configs


async def main() -> None:
    configs = load_config(os.environ["ENGINE_CONFIG"])
    endpoints = json.loads(os.environ["PRIVATE_RPC_ENDPOINTS"])
    cache = Cache()
    try:
        # Independent RPC streams; TaskGroup cancels both on an uncertain submission or audit failure.
        async with asyncio.TaskGroup() as group:
            for config in configs:
                group.create_task(
                    Chain(config, endpoints[str(config["chain_id"])], cache).run()
                )
    finally:
        await cache.client.aclose()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        LOG.error(
            "Engine stopped fail-closed (%s); inspect RPC, audit availability and transaction journals",
            type(exc).__name__,
        )
        raise SystemExit(1) from None
