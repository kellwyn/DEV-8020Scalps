"""Session and lunch-hour filter."""
from datetime import datetime
import config


def in_session() -> bool:
    if not config.FILTER_SESSION:
        return True

    now = datetime.utcnow()  # adjust to broker server TZ as needed
    now_min = now.hour * 60 + now.minute

    start = config.SESSION_START[0] * 60 + config.SESSION_START[1]
    end   = config.SESSION_END[0]   * 60 + config.SESSION_END[1]

    if not (start <= now_min < end):
        return False

    if config.AVOID_LUNCH:
        lunch_start = config.LUNCH_START[0] * 60 + config.LUNCH_START[1]
        lunch_end   = config.LUNCH_END[0]   * 60 + config.LUNCH_END[1]
        if lunch_start <= now_min < lunch_end:
            return False

    return True
