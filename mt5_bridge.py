# mt5_bridge.py — MT5 Bridge for Windows VPS
# Connects MetaTrader 5 to Linux VPS AI Trading RPG
# Auto-start on boot, sends real-time data, receives trade signals

import MetaTrader5 as mt5
import requests
import time
import json
import threading
import os
from datetime import datetime

# ===== CONFIG =====
LINUX_VPS = "http://185.84.160.106"   # Linux VPS API
API_KEY   = "mt5bridge2024"            # shared secret
SYMBOL    = "XAUUSD"
INTERVAL  = 10                          # seconds between price updates
LOG_FILE  = "C:\\mt5_bridge.log"

# Timeframe mapping
TF_MAP = {
    "M15": mt5.TIMEFRAME_M15,
    "H1":  mt5.TIMEFRAME_H1,
    "H4":  mt5.TIMEFRAME_H4,
    "D1":  mt5.TIMEFRAME_D1,
}

def log(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except:
        pass

def post(endpoint, data):
    try:
        r = requests.post(
            f"{LINUX_VPS}{endpoint}",
            json=data,
            headers={"X-API-Key": API_KEY},
            timeout=10
        )
        return r.json()
    except Exception as e:
        log(f"POST error {endpoint}: {e}")
        return None

def get_candles(symbol, tf_name, count=100):
    tf = TF_MAP.get(tf_name)
    if not tf:
        return []
    rates = mt5.copy_rates_from_pos(symbol, tf, 0, count)
    if rates is None or len(rates) == 0:
        return []
    candles = []
    for r in rates:
        candles.append({
            "time":   int(r["time"]),
            "open":   float(r["open"]),
            "high":   float(r["high"]),
            "low":    float(r["low"]),
            "close":  float(r["close"]),
            "volume": int(r["tick_volume"])
        })
    return candles

def send_candles():
    """ส่ง candle data ทุก TF ไปให้ Linux VPS"""
    for tf_name in ["M15", "H1", "H4", "D1"]:
        candles = get_candles(SYMBOL, tf_name, 200)
        if candles:
            result = post("/api/mt5/candles", {
                "symbol": SYMBOL,
                "timeframe": tf_name,
                "candles": candles
            })
            log(f"Candles {tf_name}: sent {len(candles)} bars → {result}")
        time.sleep(0.5)

def send_price():
    """ส่ง real-time price และ account info"""
    tick = mt5.symbol_info_tick(SYMBOL)
    if not tick:
        return

    acc = mt5.account_info()
    account_data = {}
    if acc:
        account_data = {
            "balance":  float(acc.balance),
            "equity":   float(acc.equity),
            "margin":   float(acc.margin),
            "freeMargin": float(acc.margin_free),
            "profit":   float(acc.profit),
            "currency": acc.currency,
            "leverage": acc.leverage,
        }

    result = post("/api/mt5/price", {
        "symbol": SYMBOL,
        "bid":    float(tick.bid),
        "ask":    float(tick.ask),
        "time":   int(tick.time),
        "account": account_data
    })
    if result:
        log(f"Price: {tick.bid}/{tick.ask} | Balance: {account_data.get('balance','?')}")

def check_signals():
    """เช็ค signal จาก Linux VPS แล้ว execute trade"""
    try:
        r = requests.get(
            f"{LINUX_VPS}/api/mt5/signal",
            headers={"X-API-Key": API_KEY},
            timeout=10
        )
        data = r.json()
        if not data.get("signal"):
            return

        signal = data["signal"]
        action    = signal.get("action")   # BUY or SELL
        lot_size  = float(signal.get("lotSize", 0.01))
        sl_price  = float(signal.get("sl", 0))
        tp_price  = float(signal.get("tp", 0))
        ticket_id = signal.get("ticket", "")

        log(f"Signal received: {action} {SYMBOL} lot={lot_size} SL={sl_price} TP={tp_price}")

        if action in ["BUY", "SELL"]:
            # เขียน signal.txt ให้ EA อ่าน
            try:
                sig_str = f"{action},{lot_size},{sl_price},{tp_price},{ticket_id}"
                with open("C:\\AI\\signal.txt", "w") as f:
                    f.write(sig_str)
                log(f"signal.txt written: {sig_str}")
            except Exception as fe:
                log(f"signal.txt error: {fe}")
            execute_trade(action, lot_size, sl_price, tp_price, ticket_id)

    except Exception as e:
        log(f"Signal check error: {e}")

def execute_trade(action, lot_size, sl_price, tp_price, ticket_id):
    """Execute trade ใน MT5"""
    tick = mt5.symbol_info_tick(SYMBOL)
    if not tick:
        log("No tick data!")
        return

    order_type = mt5.ORDER_TYPE_BUY if action == "BUY" else mt5.ORDER_TYPE_SELL
    price = tick.ask if action == "BUY" else tick.bid

    request = {
        "action":    mt5.TRADE_ACTION_DEAL,
        "symbol":    SYMBOL,
        "volume":    lot_size,
        "type":      order_type,
        "price":     price,
        "sl":        sl_price,
        "tp":        tp_price,
        "deviation": 50,
        "magic":     20240101,
        "comment":   f"AI_RPG_{ticket_id[:8]}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_RETURN,
    }

    result = mt5.order_send(request)
    if result and result.retcode == mt5.TRADE_RETCODE_DONE:
        log(f"✅ Trade EXECUTED: {action} @ {price} ticket={result.order}")
        # แจ้ง Linux VPS ว่า execute สำเร็จ
        post("/api/mt5/executed", {
            "ticket":    ticket_id,
            "mt5Ticket": result.order,
            "action":    action,
            "price":     price,
            "lot":       lot_size,
            "sl":        sl_price,
            "tp":        tp_price,
            "time":      int(time.time())
        })
    else:
        retcode = result.retcode if result else "no result"
        log(f"❌ Trade FAILED: {action} retcode={retcode}")

def close_positions():
    """เช็คและปิด position ที่ AI สั่งปิด"""
    try:
        r = requests.get(
            f"{LINUX_VPS}/api/mt5/close",
            headers={"X-API-Key": API_KEY},
            timeout=10
        )
        data = r.json()
        if not data.get("closeTicket"):
            return

        mt5_ticket = int(data["closeTicket"])
        positions = mt5.positions_get(ticket=mt5_ticket)
        if not positions:
            return

        pos = positions[0]
        tick = mt5.symbol_info_tick(pos.symbol)
        close_price = tick.bid if pos.type == mt5.POSITION_TYPE_BUY else tick.ask
        close_type  = mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY

        request = {
            "action":    mt5.TRADE_ACTION_DEAL,
            "symbol":    pos.symbol,
            "volume":    pos.volume,
            "type":      close_type,
            "position":  mt5_ticket,
            "price":     close_price,
            "deviation": 50,
            "magic":     20240101,
            "comment":   "AI_CLOSE",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_RETURN,
        }

        result = mt5.order_send(request)
        if result and result.retcode == mt5.TRADE_RETCODE_DONE:
            log(f"✅ Position closed: ticket={mt5_ticket} @ {close_price}")
        else:
            log(f"❌ Close failed: {result.retcode if result else 'no result'}")

    except Exception as e:
        log(f"Close error: {e}")

def main():
    log("=" * 50)
    log("MT5 Bridge starting...")
    log(f"Linux VPS: {LINUX_VPS}")
    log(f"Symbol: {SYMBOL}")
    log("=" * 50)

    # Initialize MT5
    if not mt5.initialize():
        log(f"MT5 initialize FAILED: {mt5.last_error()}")
        return

    log(f"MT5 initialized: version {mt5.version()}")

    # Check symbol
    symbol_info = mt5.symbol_info(SYMBOL)
    if not symbol_info:
        log(f"Symbol {SYMBOL} not found!")
        mt5.shutdown()
        return

    if not symbol_info.visible:
        mt5.symbol_select(SYMBOL, True)
        log(f"Symbol {SYMBOL} added to market watch")

    log(f"Symbol {SYMBOL} ready ✅")

    # Send initial candle data
    log("Sending initial candle data...")
    send_candles()

    candle_counter = 0
    log("Bridge running! Ctrl+C to stop.")

    while True:
        try:
            # ส่ง price ทุก 10 วิ
            send_price()

            # เช็ค signal ทุก 10 วิ
            check_signals()

            # เช็ค close ทุก 10 วิ
            close_positions()

            # ส่ง candle ใหม่ทุก 15 นาที (90 loops)
            candle_counter += 1
            if candle_counter >= 90:
                log("Refreshing candle data...")
                send_candles()
                candle_counter = 0

            time.sleep(INTERVAL)

        except KeyboardInterrupt:
            log("Stopped by user")
            break
        except Exception as e:
            log(f"Loop error: {e}")
            time.sleep(30)

    mt5.shutdown()
    log("MT5 Bridge stopped")

if __name__ == "__main__":
    main()
