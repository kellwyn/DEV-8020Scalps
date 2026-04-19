"""Position query helpers."""
import MetaTrader5 as mt5


def has_open_position(symbol: str, magic: int) -> bool:
    positions = mt5.positions_get(symbol=symbol)
    if not positions:
        return False
    return any(p.magic == magic for p in positions)
