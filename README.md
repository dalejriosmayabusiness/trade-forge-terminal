# trade-forge-terminal

Expert Advisor (MQL5) for MetaTrader 5. It is the **terminal** of the TradeForge trading system (a Maya Business instance): it only talks to Maya and only obeys orders. Design: `docs/trading/06-terminales.md` in the TradeForge instance repo.

## Status
| Step | State |
|---|---|
| Login (Bridge), `terminalConfig`, heartbeat | v0.10 (written, not yet compiled/tested in MT5) |
| Candle feed (`terminalUpsertCandles`) | v0.10 |
| On-chart panel (status + ON/OFF switch) | v0.10 |
| Alerts (`terminalPoll` / `terminalReport`) | v0.20 (written, to be compiled/tested) |
| Trade execution (LIMIT orders, fills, closes) | after alerts |

## Layout
```
Experts/TradeForgeTerminal.mq5     the EA
Include/TradeForge/TF_Json.mqh     minimal JSON parser + helpers
Include/TradeForge/TF_Maya.mqh     Bridge login + global Actions (GraphQL)
Include/TradeForge/TF_Candles.mqh  candle payload (UTC alignment, H4/D1/W1 rebuilt from H1)
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
