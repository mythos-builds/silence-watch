# Silence Watch: if the owner goes quiet, the heirs get the funds

A dead man's switch built on Reactive Network (Omni). The owner checks in from time to time. If they stop for long
enough, a reactive contract warns, waits a grace period in which any sign of life cancels, and only then tells a vault
to release. The vault holds nothing itself: the owner keeps their tokens and gives it an allowance (revocable at any
time). After a release, anyone can trigger the payout to the heirs, by fixed shares. It hands over funds, never keys.

Built for the Reactive Omni Buildathon, track « Set It and Forget It ». Testnet only (Reactive Lasna + Ethereum
Sepolia), unaudited.

**Live page:** https://mythos-builds.github.io/silence-watch/ (reads the contracts straight from the chain; the owner
checks in from it with one click) · **The run, step by step, with every transaction:**
[`runs/2026-11-12-cross2-txs.md`](runs/2026-11-12-cross2-txs.md) · explorer screenshots in [`runs/evidence/`](runs/evidence/)

## How it works

```
 owner ──checkIn()──▶ CheckIn ──Alive(owner)──┐
 (on each watched chain)                      ▼
 Cron (every N blocks) ─────────────▶ SilenceWatch.react()        (Reactive chain)
                                              │ silence passed?  → Warning  + callback onWarn
                                              │ sign in grace?   → Armed    + callback onCancel
                                              │ grace passed?    → Released + callback onRelease, stop the Cron
                                              ▼
                                         HeirVault                (destination chain)
                                re-checks CheckIn.last on its own chain, then Released (or Refused)
                                distribute(token): owner's allowance → heirs, by shares
```

| Contract | Chain | Job |
|---|---|---|
| `CheckIn` | each watched chain | Only the owner can make it emit `Alive(owner, at)`; keeps `last` for the vault. |
| `SilenceWatch` | Reactive (Lasna) | Counts the silence on Cron ticks, from the last sign it stored, on its own chain's clock. Stages Armed → Warning → Released. Shows its runway: `fundedUntil()`. After the release, a source's next sign unsubscribes that source (it would only bill the watch). |
| `HeirVault` | destination (Lasna, or the owner's home chain) | Accepts callbacks from the watch only. Re-checks the owner's last check-in before it releases. Pays out by allowance. |

`Origin`, `LoopReactive`, `LoopCallback` and `script/Deploy.s.sol` are the first generic loop (a log, a reaction,
a callback), kept as the smallest working example. `DemoToken` is for the demo only: a plain ERC-20 whose whole
supply is minted to the owner at deploy, standing in for the coins a real owner already holds.

## Threats, and what the design does about them

The guards below are mutation-tested: each one was broken on purpose, and a test failed every time.

1. **Fake signs of life.** Any contract can emit a log with the owner's address in a topic. Fake tokens do, and
   address-poisoning spam fakes `Transfer(from = victim)` on purpose. A watch that took « any act of the owner »
   (a subscription with `contract = address(0)`, or counting `Transfer(from = owner)`) could be held back forever by
   one fake sign. Worse, every matching log bills the watch, so spam can drain it into debt (see 2). `Transfer(from
   = owner)` also fires when a spender with an allowance moves the owner's coins, our own vault included.
   **Answer:** signs count only from `CheckIn` contracts named at deploy time, where `msg.sender == owner`. Each
   subscription names the contract, the `Alive` topic and the owner, so other logs are never delivered and never
   billed; `react()` checks chain, contract and owner again as a second lock. Fake Cron logs (other address or
   chain) are ignored too.
2. **Silent stop on debt.** Every Cron tick is billed, even when nothing happens. The network stops calling a
   contract that owes anything, with no error ([economy docs](https://dev.reactive.network/economy)). For this
   contract, a silent stop means the heirs get nothing. **Answer:** `fundedUntil()` shows when the money runs out:
   the last tick, plus (reserves + balance − debt) / fee per tick, times the measured gap between ticks. The price
   is the one the last tick really paid; the fee settings (`_gasPriceCoeffPer1000`, `_extraGas`) are read live from
   the system contract, since its owner can change them. Nothing is assumed about block times. The owner should
   read it at each check-in and top up well before (`depositTo(watch)` on the system contract, or a plain transfer
   and then `coverDebt()` if it is already in debt). The vault needs a little too, for its callbacks. After a
   release the watch drops its Cron subscription, so it stops paying. **Left:** nothing forces the owner to top up;
   if fees jump, the runway shown is too long until the next tick measures the new price.
3. **A sign stuck in transit.** The watch counts from the last sign it stored, so a late or missed log delays a
   release instead of causing one, unless a sign takes longer than the whole grace period to arrive. **Answer:**
   before releasing, the vault re-reads `CheckIn.last` on its own chain and refuses if the owner checked in less
   than `silence + grace` ago. **Left:** it can only re-check its own chain; a sign stuck on another chain is the
   watch's to count.
4. **A refused release locks the vault for good** (stage `Refused`). That is the safe side, but the owner then has
   to deploy again. How to re-arm safely is an open design point.
5. **The vault cannot lose what it doesn't hold.** It only moves min(allowance, balance) of a token, from the owner
   to the heirs, after a release. The owner can revoke the allowance at any time. A token that returns `false`
   stops the whole payout; tokens that return nothing (USDT style) work.

Not a legal will. Toy amounts on a testnet.

## Test

```shell
forge test              # 43 tests: the loop, the watch (incl. fundedUntil), the vault, the full loop watch → vault → payout, the demo token
```

The tests stand in for the network with `test/MockSystem.sol`, deployed at the system contract's address
`0x8888…8888` (on Lasna it is also the callback proxy): it records subscriptions and callback requests, and the
tests deliver them the way the network does.

## Deploy (Lasna)

```shell
export HEIRS=0x…,0x… SHARES=2,1          # required; OWNER defaults to the deployer
# real run: Cron10000 (about every 3 h), SILENCE 30 days, GRACE 7 days (the defaults)
# demo video: CRON=100 SILENCE=300 GRACE=240 DEMO_TOKEN=1 (about every 2 min; also deploys DemoToken, 1000 DEMO to
#   the owner, and approves the vault for all of it when the owner is the deployer)
forge script script/DeployHeir.s.sol --rpc-url https://lasna-rpc.rnk.dev/ --sender <deployer>   # dry run, sends nothing
# then add --broadcast and your wallet options; FUND_WATCH / FUND_VAULT (wei) fund the two contracts at deploy
```

Order: `CheckIn`, then `HeirVault` naming the address the watch will get next (deployer nonce + 1), then
`SilenceWatch`; the script checks the prediction. More watched chains: deploy a `CheckIn` there first, then pass
`SOURCE_CHAINS` and `SOURCE_CHECKINS` (comma lists). With `DEMO_TOKEN=1`, `DemoToken` and its approval come last, so
they don't shift the predicted address. Each transaction must find gas limit × max fee (forge sets twice the base
fee) + value in the wallet when it is sent: with about 1 lREACT, add `--with-gas-price 110gwei`.

On 2026-11-12, callbacks with Lasna itself as the destination stayed « awaiting relay » on reactscan for over 2 h:
requested, never sent, never charged. The layout below sends them to another chain.

## Deploy across two chains

The owner's coins usually live elsewhere: `script/DeployHeirCross.s.sol` puts `CheckIn`, `HeirVault` (and
`DemoToken`) on a home chain and `SilenceWatch` on Reactive. The vault names the watch before it exists (the
deployer's next address on Reactive), so send nothing else from that key on Reactive until it is done. The home
chain's callback proxy is filled in for Ethereum Sepolia, Base Sepolia and Unichain Sepolia (else `CALLBACK_PROXY`);
`FUND_VAULT` is paid in the home chain's coin.

```shell
export HOME_RPC=<home chain RPC> REACTIVE_RPC=https://lasna-rpc.rnk.dev/   # plus the variables above
forge script script/DeployHeirCross.s.sol:DeployHeirCross --rpc-url $REACTIVE_RPC --sender <deployer>   # dry run
```

Keyless Sepolia endpoints mostly refuse forge's burst of fork reads (on 2026-11-12, `sepolia.rpc.sentio.xyz` served
single calls). With one of those, deploy the same contracts one by one with `forge create` (constructor arguments
last) and check that the watch lands on the predicted address. `script/demo-run.sh` plays the demo story on either
layout (`VAULT_RPC`, `WATCH_RPC`).

Callback gas: the relayer uses the requested limit as the whole transaction's limit, the proxy keeps 150 000 (Lasna)
to 200 000 (Sepolia) of it for its own accounting, and a fresh storage slot on Sepolia now costs about 100 000. With
300 000 the vault ran out of gas there (the proxy logged `CallbackFailure`), so the watch asks for 1 000 000; fees
count the gas used, not the limit. With 1 000 000, every callback landed (below).

## The demo, run for real (2026-11-12)

Watch on Lasna (`0xA89110Cbc363ea207292FCBF97bb7c550c661510`), vault and the owner's token on Ethereum Sepolia (vault
`0x97d5056B5f86f35A5E5dCc400E74bA81985BF13C`); SILENCE 300 s, GRACE 240 s, Cron100 (a tick every 108 s).

| Time | What happened |
|---|---|
| 16:14:50 | Watch deployed; the vault is Armed. |
| 16:20:26 | 300 s of silence: the watch warns, and the vault shows Warning within seconds. |
| 16:21:02 | The owner checks in on Sepolia (tx `0xb80d3e55…e7ac`). |
| 16:21:03 → 16:21:20 | The watch sees it and cancels; the vault is Armed again. |
| 16:27:29 | Silent again: a second warning. |
| 16:32:47 → 16:33:04 | Grace over: the watch releases; the vault re-checks the last check-in and releases. |
| 16:33:13 | `distribute(DEMO)` (tx `0x8cf46291…8442`): 666.67 and 333.33 DEMO to the heirs (shares 2:1), none left with the owner. |

The watch spent 0.1575 lREACT on its ticks and reactions; the four callbacks cost the vault 1.9e-11 SepETH. The
step-by-step log is `runs/2026-11-12-cross2.log`.

## Costs on Lasna (read 2026-11-12)

Fee = price × coefficient × (gas used + surcharge): 100 gwei × 1 × (gas + 100 000). Blocks every 1.065 s on average.

| | Gas | lREACT |
|---|---|---|
| Deploy all three | 3 770 000 | ≈ 0.38 |
| + DemoToken and its approval (demo only) | + 632 000 | ≈ + 0.06 |
| One idle tick (`react()` about 33 000; `fundedUntil` counts 65 000 to err early) | + 100 000 surcharge | ≈ 0.013 to 0.017 |
| Cron10000, about 8 ticks a day | | ≈ 0.13 a day |
