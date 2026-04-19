"""
Pattern detectors for the four 8020 setups.
Each function receives the closed-bar array (newest last) and config.
"""
import numpy as np


def detect_fork(bars, cfg) -> bool:
    """
    Fork: strong down candle → rejection wick candle → failed low candle.
    Returns True when the last closed bar confirms the failed lower continuation.
    """
    if len(bars) < 4:
        return False

    b1 = bars[-2]   # last closed
    b2 = bars[-3]   # candle before
    b3 = bars[-4]   # candle before that

    range2 = b2["high"] - b2["low"]
    if range2 < cfg.SL_POINTS * 0.0001:  # guard against tiny candles
        return False

    body2      = abs(b2["close"] - b2["open"])
    lower_wick = min(b2["open"], b2["close"]) - b2["low"]

    if range2 == 0:
        return False

    if lower_wick / range2 < cfg.FORK_WICK_RATIO:
        return False

    # Candle 1 must not break below candle 2 low (failed continuation)
    if b1["low"] < b2["low"]:
        return False

    return b1["close"] > b2["low"]


def detect_h_pattern(bars, cfg) -> bool:
    """
    H Pattern: down move → weak bounce (< 80 level) → lower high → rollover.
    """
    if len(bars) < 6:
        return False

    b1 = bars[-2]
    b2 = bars[-3]
    b4 = bars[-5]
    b5 = bars[-6]

    lo_recent  = min(b4["low"], b5["low"])
    high_bounce = max(b2["high"], bars[-4]["high"])
    bounce      = high_bounce - lo_recent

    if bounce < cfg.HPATTERN_BOUNCE_PTS:
        return False

    # Lower high: candle 1 high below candle 2 high
    if b1["high"] >= b2["high"]:
        return False

    # Current close below recent swing high → rolling over
    return b1["close"] < b2["high"]


def detect_cross_section(bars, cfg) -> int:
    """
    Cross-Section: overlap zone of two same-direction candles.
    Returns 1 (long), -1 (short), or 0 (no setup).
    """
    if len(bars) < 6:
        return 0

    for i in range(2, 6):
        ba = bars[-i]
        bb = bars[-(i + 1)]

        bull_a = ba["close"] > ba["open"]
        bull_b = bb["close"] > bb["open"]

        if bull_a != bull_b:
            continue

        zone_hi = min(ba["high"], bb["high"])
        zone_lo = max(ba["low"],  bb["low"])
        if zone_hi <= zone_lo:
            continue

        current = bars[-1]["close"]
        tol     = cfg.CS_DEPTH

        in_zone = (zone_lo - tol) <= current <= (zone_hi + tol)

        if in_zone:
            return 1 if bull_a else -1

    return 0
