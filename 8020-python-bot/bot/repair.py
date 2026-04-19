"""Repair (magnet) candle detection."""
from dataclasses import dataclass


@dataclass
class RepairLevel:
    price: float
    bearish: bool   # True = magnet above price; False = magnet below


def scan_repairs(bars, lookback: int, no_wick_tol: float) -> list[RepairLevel]:
    """Scan recent bars for Repair candles (no wick on one side)."""
    repairs = []
    point   = 1.0   # NQ point = 1.00

    for bar in bars[-lookback - 1:-1]:
        op, cl, hi, lo = bar["open"], bar["close"], bar["high"], bar["low"]
        bearish = cl < op
        bullish = cl > op

        upper_wick = hi - max(op, cl)
        lower_wick = min(op, cl) - lo

        if bearish and upper_wick <= no_wick_tol * point:
            repairs.append(RepairLevel(price=max(op, cl), bearish=True))
        elif bullish and lower_wick <= no_wick_tol * point:
            repairs.append(RepairLevel(price=min(op, cl), bearish=False))

    return repairs


def nearest_repair_above(repairs: list[RepairLevel], ref: float):
    above = [r.price for r in repairs if r.bearish and r.price > ref]
    return min(above) if above else None


def nearest_repair_below(repairs: list[RepairLevel], ref: float):
    below = [r.price for r in repairs if not r.bearish and r.price < ref]
    return max(below) if below else None
