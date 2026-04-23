@../Dev-RZY/AGENT.md
@../Dev-RZY/SKILLS.md

<!-- DEV-8020Scalps — strategy-specific overrides -->

## Strategy

**NASDAQ 80/20 Level Intraday Scalping** — NQ Futures, day trading only.  
Precision scalps at price levels ending in **20 or 80** (e.g. 21,620 · 21,680).  
Three setups: Fork (reversal), H-Pattern (short continuation), Cross-Section (long or short).  
See `README.md` for full setup rules and parameter reference.

## Critical Rules

- Day trading only — NO overnight holds, close all before session end (16:00 ET)
- MANUAL_CONFIRM defaults to `true` for this strategy — never auto-execute until validated
- Execution timeframe is **200-second / M3** (not M1); context is M10
- Session filter: 09:30–16:00 ET; avoid lunch 12:00–13:30
- `config.py` currently holds MT5 credentials in plaintext — migrate to `keyring` before going live (see `../Dev-RZY/CREDENTIALS.md`)
- EA version file: `8020-mq5-ea/NQ_8020_Scalps_EA_v02.mq5` — v02 is current

## Repo Structure

```
DEV-8020Scalps/
├── 8020-mq5-ea/           NQ_8020_Scalps_EA_v02.mq5 (current)
├── 8020-python-bot/
│   ├── config.py          all toggles + risk params (NOT .env — migrate to .env)
│   └── bot/               session, levels, patterns, repair, risk, execution, position
├── 8020-signal-lab/       signal_lab.py
├── CHANGELOG.md
└── README.md
```

## Key Differences from Standard Pattern

- Config is in `config.py`, not `.env` — `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER` are there
- Risk model: fixed-point SL (10pts) + TP1 (15pts) with scale-out, not % ATR
- Lot sizing: risk% / (SL_POINTS × tick_value), capped at `MAX_LOT_SIZE=2.0`
- Two-target system: TP1 partial close (50%) → move SL to BE → runner with trailing stop
- Repair candle acts as price magnet / runner target (not a direct entry)

## Verification

| Change | Verify with |
|---|---|
| EA edit | Compile; 0 errors; test Fork/H/Cross-Section detection on NQ chart |
| Bot edit | Confirm `config.py` params match EA inputs; run diagnostic scan |
| New setup | Signal lab `--setup all` on ≥3M NQ data before enabling |

## Subagents

| Task | Command |
|---|---|
| Review code | `use the code-reviewer subagent` |
| Security scan | `use the security-reviewer subagent` — especially for `config.py` credentials |
| Check bot | `use the bot-health-check subagent` |
| Deploy EA | `use the ea-deployer subagent` |
| Commit + push | `use the git-push subagent` |
