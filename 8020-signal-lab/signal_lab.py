"""
NQ 8020 Scalps – Signal Lab
Version : 1.0.0
Date    : 2026-04-20
Author  : kellwyn

Standalone research environment for back-analysing 80/20 level setups.
Loads historical NQ bars from MT5, runs all pattern detectors, and exports
a signal log for review and statistics.

Usage:
    python signal_lab.py --start 2025-01-01 --end 2025-12-31 --setup all
    python signal_lab.py --setup fork --start 2025-06-01 --end 2025-09-01
"""

import argparse
import sys
import os
import MetaTrader5 as mt5
import pandas as pd
from datetime import datetime

# allow imports from the bot package sibling directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "8020-python-bot"))

import config
from bot.levels   import is_2080_level
from bot.patterns import detect_fork, detect_h_pattern, detect_cross_section
from bot.repair   import scan_repairs


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="8020 Signal Lab")
    p.add_argument("--start",  default="2025-01-01", help="Start date YYYY-MM-DD")
    p.add_argument("--end",    default="2025-12-31", help="End date YYYY-MM-DD")
    p.add_argument("--setup",  default="all",
                   choices=["all", "fork", "hpattern", "crosssection"],
                   help="Setup to analyse")
    p.add_argument("--output", default="signals/signal_log.csv",
                   help="Output CSV path")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Core scan
# ---------------------------------------------------------------------------
def run_scan(bars: pd.DataFrame, setup: str) -> list[dict]:
    signals = []
    arr = bars.to_records(index=False)

    for i in range(20, len(arr)):
        window = arr[max(0, i - 20): i + 1]
        tick   = arr[i]

        ask = tick["close"]  # approximate for historical
        bid = tick["close"]

        level_long  = is_2080_level(bid, config)
        level_short = is_2080_level(ask, config, short=True)

        if (setup in ("all", "fork")) and level_long:
            if detect_fork(window, config):
                signals.append(_make_signal(tick, "Fork", "LONG"))

        if (setup in ("all", "hpattern")) and level_short:
            if detect_h_pattern(window, config):
                signals.append(_make_signal(tick, "HPattern", "SHORT"))

        if setup in ("all", "crosssection"):
            cs_dir = detect_cross_section(window, config)
            if cs_dir == 1 and level_long:
                signals.append(_make_signal(tick, "CrossSection", "LONG"))
            elif cs_dir == -1 and level_short:
                signals.append(_make_signal(tick, "CrossSection", "SHORT"))

    return signals


def _make_signal(tick, setup: str, direction: str) -> dict:
    return {
        "datetime":  datetime.utcfromtimestamp(int(tick["time"])),
        "setup":     setup,
        "direction": direction,
        "price":     round(tick["close"], 2),
        "sl_price":  round(tick["close"] - config.SL_POINTS, 2)
                     if direction == "LONG"
                     else round(tick["close"] + config.SL_POINTS, 2),
        "tp1_price": round(tick["close"] + config.TP1_POINTS, 2)
                     if direction == "LONG"
                     else round(tick["close"] - config.TP1_POINTS, 2),
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    args = parse_args()

    if not mt5.initialize():
        print("MT5 init failed:", mt5.last_error())
        return

    start = datetime.strptime(args.start, "%Y-%m-%d")
    end   = datetime.strptime(args.end,   "%Y-%m-%d")

    print(f"Fetching {config.SYMBOL} bars {args.start} → {args.end} ...")
    raw = mt5.copy_rates_range(config.SYMBOL, config.TF_EXEC, start, end)
    mt5.shutdown()

    if raw is None or len(raw) == 0:
        print("No data returned from MT5.")
        return

    bars = pd.DataFrame(raw)
    bars["time"] = pd.to_datetime(bars["time"], unit="s")
    print(f"Loaded {len(bars)} bars.")

    signals = run_scan(bars.to_records(index=False), args.setup)
    print(f"Found {len(signals)} signals.")

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    df = pd.DataFrame(signals)
    df.to_csv(args.output, index=False)
    print(f"Signal log saved → {args.output}")

    # Quick summary
    if not df.empty:
        print("\n--- Setup Distribution ---")
        print(df.groupby(["setup", "direction"]).size().to_string())


if __name__ == "__main__":
    main()
