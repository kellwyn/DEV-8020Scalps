"""
NQ 8020 Scalps – Python Trading Bot
Version : 1.0.0
Date    : 2026-04-20
Author  : kellwyn

Automates trade execution for the NASDAQ 80/20 Level strategy.
Connects to MetaTrader 5 via the mt5 Python library.

Setup toggles, risk params, and session filters mirror the EA inputs
so the bot and EA can be used interchangeably or in tandem.
"""

import MetaTrader5 as mt5
from datetime import datetime, time as dtime
import time
import logging
import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("logs/bot.log"),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("8020-bot")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    log.info("NQ 8020 Scalps Bot v1.0.0 starting...")

    if not mt5.initialize(login=config.MT5_LOGIN,
                          password=config.MT5_PASSWORD,
                          server=config.MT5_SERVER):
        log.error("MT5 init failed: %s", mt5.last_error())
        return

    log.info("Connected to MT5 | account=%s", mt5.account_info().login)

    try:
        run_loop()
    finally:
        mt5.shutdown()
        log.info("MT5 disconnected.")


# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------
def run_loop():
    from bot.session   import in_session
    from bot.levels    import is_2080_level
    from bot.patterns  import detect_fork, detect_h_pattern, detect_cross_section
    from bot.repair    import scan_repairs
    from bot.risk      import calc_lot_size, get_tp1_points
    from bot.execution import execute_long, execute_short, manage_runner
    from bot.position  import has_open_position

    last_bar = None

    while True:
        try:
            bars = mt5.copy_rates_from_pos(config.SYMBOL, config.TF_EXEC, 0, 50)
            if bars is None or len(bars) < 10:
                time.sleep(1)
                continue

            current_bar_time = bars[-1]["time"]
            if current_bar_time == last_bar:
                time.sleep(0.5)
                continue
            last_bar = current_bar_time

            if not in_session():
                continue

            if has_open_position(config.SYMBOL, config.MAGIC):
                manage_runner(config.SYMBOL, config.MAGIC)
                continue

            repairs = scan_repairs(bars, config.REPAIR_LOOKBACK,
                                   config.REPAIR_NO_WICK_TOL)
            tick    = mt5.symbol_info_tick(config.SYMBOL)
            ask, bid = tick.ask, tick.bid

            # -- Fork (Long) -------------------------------------------
            if config.ENABLE_FORK and is_2080_level(bid, config):
                if detect_fork(bars, config):
                    execute_long("Fork", ask, bars, repairs, config)
                    continue

            # -- H Pattern (Short) -------------------------------------
            if config.ENABLE_H_PATTERN and is_2080_level(ask, config, short=True):
                if detect_h_pattern(bars, config):
                    execute_short("HPattern", bid, bars, repairs, config)
                    continue

            # -- Cross-Section -----------------------------------------
            if config.ENABLE_CROSS_SECTION:
                cs_dir = detect_cross_section(bars, config)
                if cs_dir == 1 and is_2080_level(bid, config):
                    execute_long("CrossSection", ask, bars, repairs, config)
                elif cs_dir == -1 and is_2080_level(ask, config, short=True):
                    execute_short("CrossSection", bid, bars, repairs, config)

        except KeyboardInterrupt:
            log.info("Interrupted by user.")
            break
        except Exception as exc:
            log.exception("Loop error: %s", exc)
            time.sleep(2)


if __name__ == "__main__":
    main()
