"""80/20 level detection helpers."""
import math


def is_2080_level(price: float, cfg, short: bool = False) -> bool:
    """Return True if price is within tolerance of a x20 or x80 level."""
    mod100 = math.floor(price) % 100
    dist20 = min(abs(mod100 - 20), abs(mod100 - 120))
    dist80 = min(abs(mod100 - 80), abs(mod100 - 180))
    return min(dist20, dist80) <= cfg.LEVEL_TOLERANCE_PTS
