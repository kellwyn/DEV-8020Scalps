# Changelog – NQ 8020 Scalps

All notable changes are documented here.
Format: `[vX.Y.Z] YYYY-MM-DD – description`

---

## [v1.0.0] 2026-04-20 – Initial Release

### Expert Advisor (`8020-mq5-ea`)
- Four setup detectors: Fork, H Pattern, Cross-Section, Repair (magnet)
- Per-setup enable/disable input parameters
- Risk model: % account risk → dynamic lot size with hard lot cap
- SL/TP inputs: SL_Points, TP1_Points, Use_RR_Ratio, RR_Ratio, Max_Lot_Size
- Scale-out at TP1 (50 %), auto break-even on runner
- NY session filter with lunch-hour avoidance
- Repair candle scanner for target magnets
- Magic number: 8020 | Symbol target: NQ Futures

### Python Bot (`8020-python-bot`)
- MT5 Python API integration
- Modular package: session, levels, patterns, repair, risk, execution, position
- All setup toggles and risk params mirrored from EA via config.py
- Per-trade logging to `logs/bot.log`

### Signal Lab (`8020-signal-lab`)
- Historical scan over MT5 data for all four setups
- CLI flags: `--setup`, `--start`, `--end`, `--output`
- CSV signal log with datetime, setup, direction, entry, SL, TP1 columns
- Setup distribution summary printed to console

---

## Upcoming

- v1.1.0 – Backtesting stats module in Signal Lab (win rate, avg R, drawdown)
- v1.2.0 – Dashboard visualiser for signal log review
- v1.3.0 – Partial-close automation in Python bot (TP1 scale-out)
- v2.0.0 – Live paper-trading mode with Telegram alerts
