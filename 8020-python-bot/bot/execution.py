"""Order execution and runner management."""
import MetaTrader5 as mt5
import logging
from bot.repair import nearest_repair_above, nearest_repair_below
from bot.risk   import calc_lot_size, get_tp1_points

log = logging.getLogger("8020-bot")


def _send_order(request: dict) -> bool:
    result = mt5.order_send(request)
    if result.retcode == mt5.TRADE_RETCODE_DONE:
        log.info("Order filled: ticket=%s lots=%s", result.order, request["volume"])
        return True
    log.error("Order failed: retcode=%s comment=%s", result.retcode, result.comment)
    return False


def execute_long(label, ask, bars, repairs, cfg):
    lots  = calc_lot_size(cfg)
    sl    = ask - cfg.SL_POINTS
    tp1   = ask + get_tp1_points(cfg)
    above = nearest_repair_above(repairs, ask)
    tp    = above if (above and above > tp1) else tp1

    request = {
        "action":   mt5.TRADE_ACTION_DEAL,
        "symbol":   cfg.SYMBOL,
        "volume":   lots,
        "type":     mt5.ORDER_TYPE_BUY,
        "price":    ask,
        "sl":       sl,
        "tp":       tp,
        "magic":    cfg.MAGIC,
        "comment":  f"8020-{label}-v1.0.0",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    log.info("LONG [%s] ask=%.2f SL=%.2f TP=%.2f lots=%.2f", label, ask, sl, tp, lots)
    _send_order(request)


def execute_short(label, bid, bars, repairs, cfg):
    lots  = calc_lot_size(cfg)
    sl    = bid + cfg.SL_POINTS
    tp1   = bid - get_tp1_points(cfg)
    below = nearest_repair_below(repairs, bid)
    tp    = below if (below and below < tp1) else tp1

    request = {
        "action":   mt5.TRADE_ACTION_DEAL,
        "symbol":   cfg.SYMBOL,
        "volume":   lots,
        "type":     mt5.ORDER_TYPE_SELL,
        "price":    bid,
        "sl":       sl,
        "tp":       tp,
        "magic":    cfg.MAGIC,
        "comment":  f"8020-{label}-v1.0.0",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    log.info("SHORT [%s] bid=%.2f SL=%.2f TP=%.2f lots=%.2f", label, bid, sl, tp, lots)
    _send_order(request)


def manage_runner(symbol: str, magic: int):
    """Move SL to break-even on runner after partial close."""
    positions = mt5.positions_get(symbol=symbol)
    if not positions:
        return

    for pos in positions:
        if pos.magic != magic:
            continue

        entry  = pos.price_open
        cur_sl = pos.sl

        if pos.type == mt5.ORDER_TYPE_BUY and cur_sl < entry:
            mt5.order_send({
                "action":   mt5.TRADE_ACTION_SLTP,
                "symbol":   symbol,
                "position": pos.ticket,
                "sl":       entry,
                "tp":       pos.tp,
            })
            log.info("Runner BE set for ticket %s", pos.ticket)

        elif pos.type == mt5.ORDER_TYPE_SELL and (cur_sl > entry or cur_sl == 0):
            mt5.order_send({
                "action":   mt5.TRADE_ACTION_SLTP,
                "symbol":   symbol,
                "position": pos.ticket,
                "sl":       entry,
                "tp":       pos.tp,
            })
            log.info("Runner BE set for ticket %s", pos.ticket)
