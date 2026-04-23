"""
Bot configuration – mirrors EA input parameters.
Edit this file to toggle setups and adjust risk without changing core logic.

Credentials are read from Windows Credential Manager via keyring.
Store once:
  python -c "import keyring; keyring.set_password('mt5', '8020_login',    'YOUR_ACCOUNT')"
  python -c "import keyring; keyring.set_password('mt5', '8020_password', 'YOUR_PASSWORD')"
  python -c "import keyring; keyring.set_password('mt5', '8020_server',   'YOUR_SERVER')"

Non-sensitive overrides can also be set in a .env file (see .env.example).
"""

import os
import keyring
import MetaTrader5 as mt5
from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# MT5 Connection — credentials from keyring, never hardcoded
# ---------------------------------------------------------------------------
_profile     = os.getenv("KEYRING_PROFILE", "8020")
MT5_LOGIN    = int(keyring.get_password("mt5", f"{_profile}_login")    or os.getenv("MT5_LOGIN",    "0"))
MT5_PASSWORD =     keyring.get_password("mt5", f"{_profile}_password") or os.getenv("MT5_PASSWORD", "")
MT5_SERVER   =     keyring.get_password("mt5", f"{_profile}_server")   or os.getenv("MT5_SERVER",   "")
MT5_PATH     = os.getenv("MT5_PATH", "")

# ---------------------------------------------------------------------------
# Instrument
# ---------------------------------------------------------------------------
SYMBOL   = "NQ100m"        # adjust to broker's NQ symbol (NQ, MNQ, NAS100, etc.)
TF_EXEC  = mt5.TIMEFRAME_M3   # 200-second equivalent; swap to custom TF if broker supports it
MAGIC    = 8020

# ---------------------------------------------------------------------------
# Setup Toggles
# ---------------------------------------------------------------------------
ENABLE_FORK           = True
ENABLE_H_PATTERN      = True
ENABLE_CROSS_SECTION  = True
ENABLE_REPAIR_TARGET  = True

# ---------------------------------------------------------------------------
# Level Detection
# ---------------------------------------------------------------------------
LEVEL_TOLERANCE_PTS   = 5.0   # ± points within a 20/80 level
REPAIR_LOOKBACK       = 20    # bars to scan for Repair candles
REPAIR_NO_WICK_TOL    = 1.0   # pts tolerance for "no wick"

# ---------------------------------------------------------------------------
# Session Filter (all times in broker server time, 24-hour)
# ---------------------------------------------------------------------------
FILTER_SESSION      = True
SESSION_START       = (9, 30)   # (hour, minute)
SESSION_END         = (16, 0)
AVOID_LUNCH         = True
LUNCH_START         = (12, 0)
LUNCH_END           = (13, 30)

# ---------------------------------------------------------------------------
# Risk Management
# ---------------------------------------------------------------------------
RISK_PER_TRADE_PCT  = 1.0    # % of account balance risked per trade
SL_POINTS           = 10.0   # stop loss in points
TP1_POINTS          = 15.0   # first target in points
USE_RR_RATIO        = False  # override TP1 with SL * RR_RATIO if True
RR_RATIO            = 1.5
MAX_LOT_SIZE        = 2.0    # hard cap (0 = no cap)
SCALE_OUT_PCT       = 50.0   # % of position to close at TP1

# ---------------------------------------------------------------------------
# Trade Management
# ---------------------------------------------------------------------------
MOVE_BE_AFTER_TP1   = True
ENABLE_RUNNER       = True
RUNNER_TRAIL_PTS    = 10.0   # trailing stop on runner (0 = disabled)

# ---------------------------------------------------------------------------
# Pattern Sensitivity
# ---------------------------------------------------------------------------
FORK_WICK_RATIO     = 0.5    # lower-wick / range min ratio for Fork rejection candle
HPATTERN_BOUNCE_PTS = 8.0    # minimum bounce pts before H rolls over
CS_DEPTH            = 5.0    # pts tolerance for cross-section re-test
