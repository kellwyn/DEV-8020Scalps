"""Lot size and TP calculation."""
import MetaTrader5 as mt5
import math
import logging

log = logging.getLogger("8020-bot")


def calc_lot_size(cfg) -> float:
    info    = mt5.account_info()
    balance = info.balance

    risk_money = balance * (cfg.RISK_PER_TRADE_PCT / 100.0)
    sym_info   = mt5.symbol_info(cfg.SYMBOL)

    if sym_info is None:
        return sym_info.volume_min

    tick_val  = sym_info.trade_tick_value
    tick_size = sym_info.trade_tick_size
    point     = sym_info.point
    point_val = tick_val * (point / tick_size) if tick_size > 0 else 1.0

    if point_val <= 0:
        return sym_info.volume_min

    lots = risk_money / (cfg.SL_POINTS * point_val)
    lots = max(sym_info.volume_min,
               math.floor(lots / sym_info.volume_step) * sym_info.volume_step)

    if cfg.MAX_LOT_SIZE > 0:
        lots = min(lots, cfg.MAX_LOT_SIZE)

    lots = min(lots, sym_info.volume_max)
    return round(lots, 2)


def get_tp1_points(cfg) -> float:
    if cfg.USE_RR_RATIO:
        return cfg.SL_POINTS * cfg.RR_RATIO
    return cfg.TP1_POINTS
