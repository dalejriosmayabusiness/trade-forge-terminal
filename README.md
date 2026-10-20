# trade-forge-terminal

Expert Advisor (MQL5) for MetaTrader 5. It is the **terminal** of the TradeForge trading system (a Maya Business instance): it only talks to Maya and only obeys orders. Design: `docs/trading/06-terminales.md` in the TradeForge instance repo.

## Status
| Step | State |
|---|---|
| Login (Bridge), `terminalConfig`, heartbeat | v0.10 (written, not yet compiled/tested in MT5) |
| Candle feed (`terminalUpsertCandles`) | v0.10 |
| On-chart panel (status + ON/OFF switch) | v0.10 |
| Alerts (`terminalPoll` / `terminalReport`) | v0.20 (written, to be compiled/tested) |
| Trade execution (LIMIT orders, fills, closes) | v0.30 (written, to be compiled/tested) |

## Layout
```
Experts/TradeForgeTerminal.mq5     the EA
Include/TradeForge/TF_Json.mqh     minimal JSON parser + helpers
Include/TradeForge/TF_Maya.mqh     Bridge login + global Actions (GraphQL)
Include/TradeForge/TF_Candles.mqh  candle payload (UTC alignment, H4/D1/W1 rebuilt from H1)
Include/TradeForge/TF_Alerts.mqh    price alerts watched on tick ranges
Include/TradeForge/TF_Trades.mqh    trade execution by reconciliation with the broker
Include/TradeForge/TF_Commands.mqh  command runner (orders from Maya) + BACKFILL_CANDLES
Include/TradeForge/TF_Panel.mqh    chart panel
```

## Install
1. Copy this folder to `<MT5 data folder>/MQL5/Experts/TradeForge/` (File > Open Data Folder). Keep the `Experts/` and `Include/` sub-folders.
2. Open `Experts/TradeForgeTerminal.mq5` in MetaEditor and compile (F7).
3. MT5: Tools > Options > Expert Advisors: tick **Allow WebRequest for listed URL** and add the Maya API URL (`https://api-dev-tradeforge.tunnel.maya.business`). Enable **Algo Trading**.
4. Drag the EA onto **one** chart and fill the inputs: `MayaUrl`, `BridgeKey`, `BridgeSecret`, `TerminalToken`.
5. In Maya, create the `Terminal` (strategy, `symbolMap`, `timeframes`) and press **Generate Terminal Token** (shown once).

> MT5 stores EA inputs in the local profile in clear text. Do not share profiles or screenshots of the inputs. The EA never writes credentials or tokens to the log.

## Panel
Top-left of the chart. Rows: status, account (DEMO/REAL), terminal, strategy, mode (PAPER/LIVE), instrument, feeder, heartbeat, candles, last error.

* **ACTIVE / PAUSED button**: pauses the EA completely (no heartbeats, so Maya marks the terminal OFFLINE and hands the instrument to another terminal). The choice is remembered across restarts (terminal global variable `TradeForge_Active`).
* `-` / `+` collapses the panel.
* To stop a terminal from Maya instead, set `Terminal.enabled = false` (the panel shows "Disabled in Maya").

## Version
The panel's last row shows `vX.Y.Z (built <compile time>)`. It is only for you to check that a recompiled EA is the one running; it is not sent to Maya. The maintainer bumps `TF_VERSION` on every change.

## Behaviour
* The terminal loads **all** its configuration from Maya (`terminalConfig`) and refreshes it every 10 minutes; heartbeat and mode changes apply without restarting.
* Only the **feeder** of an instrument sends candles. Each minute it sends the newest 3 bars of every timeframe, skipping unchanged ones.
* Maya stores candles on UTC boundaries. M5/M15/H1 are shifted by the broker's server offset; H4/D1/W1 are rebuilt from H1 bars on UTC boundaries.

## Trades (v0.30)
The EA only obeys: it does **not** check the account type (demo/real), the strategy mode or the lot minimum; Maya's triggers already filtered the trade. It places a LIMIT order with SL and TP on the account it is attached to.

* Every second the cached live trades (from `terminalPoll`) are **reconciled** with the broker, so restarts and lost reports heal themselves: `PENDING` -> order sent -> `PLACED` (ticket in `externalOrderId`) or `REJECTED` (broker message in `botMessage`); fill -> `OPEN`; closed -> `CLOSED_TP` / `CLOSED_SL` with exit price, time and net P&L (profit + commission + swap + fee, in account currency); `CANCEL_REQUESTED` -> order removed -> `CANCELLED`; `validUntil` passed -> order removed -> `EXPIRED`.
* The Trade id travels in the order comment: an order that was sent but never reported is found again, never re-sent. Orders carry the `MagicNumber` input.
* Closes that were not TP/SL (manual close, stop out) are reported as `CLOSED_TP` or `CLOSED_SL` by the sign of the result, with the real cause in `closeReason` (`MANUAL`, `STOP_OUT`, `EXPIRED`...).
* Pausing from the panel stops new orders but **does not cancel pending orders or touch open positions** (their SL/TP live in the broker).
* One terminal = one EA = one instrument. For 6 instruments on the same account run 6 EAs with 6 terminals (use the same `MagicNumber`; the symbol tells them apart). The account may be netting.
* "Algo trading" must be enabled in MT5; the panel row *Trades* turns red (`ALGO TRADING OFF`) otherwise.

## Commands from Maya (v0.40)
Maya has a queue of orders for each terminal (object **Terminal Command**). The heartbeat returns this terminal's `PENDING`/`RUNNING` commands; the EA runs **one at a time, in small slices** (it keeps watching alerts and trades in between) and reports progress (`terminalCommandReport`). Cancelling a command in Maya stops it at the next heartbeat. A command type the EA does not know is reported `FAILED: unsupported` (so Maya can be ahead of old EAs).

* **Sending a command**: admin-only Global Action **Send Terminal Command** (lightning menu) opens a form (terminal, command type and its parameters); the Trading Desk > Terminals tab opens the same form from each terminal card. Other Maya code can use the Action `createTerminalCommand {terminalId, type, params}`.
* **BACKFILL_CANDLES**: sends the closed history from MT5 with **a candle count per timeframe** (any number from 0 to 20 000, e.g. 5, 10 or 5000; 0 skips the timeframe; the form has quick presets and the defaults M5 3000, M15 2000, H1 1500, H4 600, D1 365, W1 104). Existing candles are skipped, so it is safe to repeat. Only the feeder can run it.
* Input `ServerDstRule`: how the broker's server clock switches summer/winter time (EU or US dates, or none). It is only used to convert **historical** bars to UTC (the live feed uses the current offset). Check it if old bars look shifted by one hour.
* **SYNC_INSTRUMENT**: reads the real contract specification of the symbol from MT5 (tick size, tick value in the account currency, lot minimum / step / maximum, pip size) and updates the Instrument in Maya. Those numbers drive the lot-size calculation of the Trade triggers, so run it once per new instrument. No parameters.
* **Adding a command**: describe the type in Maya (`COMMAND_TYPES` in the Actions prelude), derive a class from `CCommand` in `TF_Commands.mqh`, and add one line to `TF_CreateCommand()`.
