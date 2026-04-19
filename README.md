# DEV-8020Scalps

**Strategy:** NASDAQ 80/20 Level Intraday Scalping Model  
**Instrument:** NQ Futures (NASDAQ)  
**Style:** Day Trading – precision scalps at 20/80 price endings  
**Version:** 1.0.0

---

## Strategy Overview

The 80/20 model enters NQ Futures when price reaches a level whose last two
digits end in **20** or **80** (e.g. 21,620 · 21,680 · 21,720) and a
recognisable structure confirms a reaction.

### Core Setups

| Setup | Type | Description |
|---|---|---|
| **Fork** | Long reversal | Failed lower continuation near 20/80; rejection wick → entry on failed low |
| **H Pattern** | Short continuation | Weak bounce into 80 rolls over; re-test of level triggers short |
| **Cross-Section** | Long or Short | Overlap zone of two same-direction candles + 20/80 confluence |
| **Repair (Magnet)** | Target concept | Candle with no wick on one side acts as price magnet; used as runner target |

### Risk Model (defaults)

| Parameter | Default |
|---|---|
| Stop loss | 10 points |
| First target (TP1) | 15 points |
| Scale-out at TP1 | 50 % of position |
| Move SL to BE | After TP1 hit |
| Risk per trade | 1 % of account balance |
| Max lot cap | 2.0 lots |

### Timeframes

- **10-minute** – broader structure and context
- **200-second** – execution (MT5: use custom chart; bot defaults to M3 as nearest built-in)

---

## Repository Structure

```
DEV-8020Scalps/
├── 8020-mq5-ea/           MetaTrader 5 Expert Advisor
│   └── NQ_8020_Scalps_EA.mq5
├── 8020-python-bot/       Python trading bot (MT5 Python API)
│   ├── main.py
│   ├── config.py          All toggles and risk params
│   ├── bot/               Modular sub-package
│   │   ├── session.py
│   │   ├── levels.py
│   │   ├── patterns.py
│   │   ├── repair.py
│   │   ├── risk.py
│   │   ├── execution.py
│   │   └── position.py
│   └── requirements.txt
├── 8020-signal-lab/       Historical signal scanner
│   ├── signal_lab.py
│   └── requirements.txt
├── CHANGELOG.md
└── README.md
```

---

## Quick Start

### MetaTrader 5 EA

1. Copy `8020-mq5-ea/NQ_8020_Scalps_EA.mq5` to your MT5 `Experts/` folder.
2. Compile in MetaEditor.
3. Attach to an NQ chart (200-second or M3 for execution; M10 for context).
4. Configure inputs – toggle each setup on/off as needed.

### Python Bot

```bash
cd 8020-python-bot
pip install -r requirements.txt
# Edit config.py: MT5_LOGIN, MT5_PASSWORD, MT5_SERVER, SYMBOL
python main.py
```

### Signal Lab

```bash
cd 8020-signal-lab
pip install -r requirements.txt
# Edit ../8020-python-bot/config.py for symbol/timeframe
python signal_lab.py --start 2025-01-01 --end 2025-12-31 --setup all
```

---

## Input Parameter Reference (EA & Bot)

### Setup Toggles
| Parameter | Default | Description |
|---|---|---|
| `Enable_Fork` | `true` | Fork reversal setup |
| `Enable_HPattern` | `true` | H Pattern short continuation |
| `Enable_CrossSection` | `true` | Cross-Section precision entry |
| `Enable_Repair_Target` | `true` | Use Repair candle as runner target |

### Risk Management
| Parameter | Default | Description |
|---|---|---|
| `SL_Points` | `10` | Fixed stop loss in points |
| `TP1_Points` | `15` | First scale-out target |
| `Use_RR_Ratio` | `false` | Override TP1 with SL × RR_Ratio |
| `RR_Ratio` | `1.5` | Reward-to-risk multiplier |
| `Risk_Per_Trade_Pct` | `1.0` | % of balance risked per trade |
| `Max_Lot_Size` | `2.0` | Hard cap on lot size (0 = no cap) |
| `Scale_Out_Pct` | `50` | % of position closed at TP1 |

---

## Versioning

Semantic versioning: `vMAJOR.MINOR.PATCH`

- **MAJOR** – new setup added or logic overhaul
- **MINOR** – parameter additions, new module
- **PATCH** – bug fixes, tuning

See [CHANGELOG.md](CHANGELOG.md) for full history.
