#!/usr/bin/env python3
#
# X6200 — sube los QSO nuevos al QRZ Logbook cuando hay WiFi.
#
# Uso:
#   qrz-upload.py --once     corre una pasada (para probar)
#   qrz-upload.py --loop     queda en bucle (lo arranca /etc/init.d/S55qrz-upload)
#   qrz-upload.py --status   muestra configuracion y estado sin subir nada
#   qrz-upload.py --adif     imprime el ADIF de todos los QSO del log (subida manual)
#
# Configuracion: /mnt/qrz.conf  (se crea con la plantilla la primera vez)
#   enabled=1
#   api_key=XXXX-XXXX-XXXX-XXXX      # QRZ Logbook API access key
#   interval=30                      # segundos entre pasadas
#
# Estado: /mnt/qrz_upload.state  (ultimo rowid subido con exito)
# Log:    /mnt/qrz-upload.log
#
# API: https://logbook.qrz.com/api  (POST KEY=...&ACTION=INSERT&ADIF=...)
#      respuesta: RESULT=OK|REPLACE|FAIL&REASON=...
#      Requiere suscripcion QRZ para INSERT (segun la guia de QRZ).
#
# SPDX-License-Identifier: LGPL-2.1-or-later

import os
import sqlite3
import ssl
import sys
import time
import urllib.parse
import urllib.request

CONF = os.environ.get("QRZ_CONF", "/mnt/qrz.conf")
STATE = os.environ.get("QRZ_STATE", "/mnt/qrz_upload.state")
COOLDOWN = os.environ.get("QRZ_COOLDOWN", "/mnt/qrz_upload.cooldown")
LOG = os.environ.get("QRZ_LOG", "/mnt/qrz-upload.log")
DB = os.environ.get("QRZ_DB", "/mnt/qso_log.db")
API = "https://logbook.qrz.com/api"
CA = os.environ.get("QRZ_CA", "/etc/ssl/certs/ca-certificates.crt")
UA = "X6200-QRZ-Upload/1.0 (LU2DSX)"
WLAN = os.environ.get("QRZ_WLAN", "/sys/class/net/wlan0/operstate")

CONF_TEMPLATE = """# X6200 QRZ Logbook uploader
# Poné tu API access key del QRZ Logbook (https://www.qrz.com/logbook -> API key)
# INSERT por API requiere suscripcion QRZ.
enabled=1
api_key=
interval=30
"""


def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime()) + " " + msg
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 128 * 1024:
            os.replace(LOG, LOG + ".1")
    except OSError:
        pass
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_conf():
    conf = {"enabled": "0", "api_key": "", "interval": "30"}
    if not os.path.exists(CONF):
        try:
            with open(CONF, "w") as f:
                f.write(CONF_TEMPLATE)
            os.chmod(CONF, 0o600)
            log("creada plantilla %s (falta api_key)" % CONF)
        except OSError as e:
            log("no puedo crear %s: %s" % (CONF, e))
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                conf[k.strip().lower()] = v.strip()
    except OSError as e:
        log("no puedo leer %s: %s" % (CONF, e))
    return conf


def network_up():
    try:
        with open(WLAN) as f:
            return f.read().strip() == "up"
    except OSError:
        return False


def read_last_rowid():
    try:
        with open(STATE) as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def write_last_rowid(rowid):
    tmp = STATE + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(str(rowid))
        os.replace(tmp, STATE)
    except OSError as e:
        log("no puedo escribir %s: %s" % (STATE, e))


def read_cooldown():
    """Segundos que faltan para reintentar (0 si toca ahora)."""
    try:
        with open(COOLDOWN) as f:
            return max(0, int(f.read().strip() or "0") - int(time.time()))
    except (OSError, ValueError):
        return 0


def write_cooldown(seconds):
    try:
        with open(COOLDOWN, "w") as f:
            f.write(str(int(time.time()) + seconds))
    except OSError as e:
        log("no puedo escribir %s: %s" % (COOLDOWN, e))


MODE_TO_ADIF = {1: "SSB", 2: "AM", 3: "FM", 4: "CW", 5: "FT8", 6: "JS8", 7: "FT4", 8: "RTTY"}


def adif_field(tag, value):
    value = str(value)
    return "<%s:%d>%s " % (tag, len(value), value)


def adif_for_row(row):
    # row: rowid, ts, freq(MHz), band(int m), mode(int), local_call, remote_call,
    #      rsts, rstr, local_grid, remote_grid
    rowid, ts, freq, band, mode, local_call, remote_call, rsts, rstr, lgrid, rgrid = row
    adif_mode = MODE_TO_ADIF.get(int(mode))
    if not adif_mode or not band:
        return None
    try:
        date, clock = ts.split(" ")
        y, m, d = date.split("-")
        hh, mm, ss = clock.split(":")
    except (ValueError, AttributeError):
        return None
    s = adif_field("CALL", remote_call)
    s += adif_field("QSO_DATE", y + m + d)
    s += adif_field("TIME_ON", hh + mm + ss)
    s += adif_field("BAND", "%dm" % int(band))
    s += adif_field("MODE", adif_mode)
    s += adif_field("FREQ", "%.6f" % float(freq))
    s += adif_field("RST_SENT", rsts if rsts is not None else 0)
    s += adif_field("RST_RCVD", rstr if rstr is not None else 0)
    s += adif_field("STATION_CALLSIGN", local_call)
    if lgrid:
        s += adif_field("MY_GRIDSQUARE", lgrid)
    if rgrid:
        s += adif_field("GRIDSQUARE", rgrid)
    s += "<eor>"
    return s


def pending_rows(last_rowid):
    if not os.path.exists(DB):
        return []
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=10)
        cur = con.execute(
            "select rowid, ts, freq, band, mode, local_callsign, remote_callsign, "
            "rsts, rstr, local_grid, remote_grid from qso_log where rowid > ? "
            "order by rowid", (last_rowid,))
        rows = cur.fetchall()
        con.close()
        return rows
    except sqlite3.Error as e:
        log("sqlite: %s" % e)
        return []


def upload(api_key, adif):
    body = urllib.parse.urlencode({"KEY": api_key, "ACTION": "INSERT", "ADIF": adif}).encode()
    req = urllib.request.Request(API, data=body, method="POST",
                                 headers={"User-Agent": UA,
                                          "Content-Type": "application/x-www-form-urlencoded"})
    ctx = ssl.create_default_context(cafile=CA if os.path.exists(CA) else None)
    with urllib.request.urlopen(req, timeout=20, context=ctx) as resp:
        return resp.read().decode("utf-8", "replace")


def run_once(conf):
    api_key = conf.get("api_key", "").strip()
    if not api_key:
        log("sin api_key en %s; no subo nada" % CONF)
        return 0
    wait = read_cooldown()
    if wait > 0:
        return 0
    if not network_up():
        return 0
    last = read_last_rowid()
    rows = pending_rows(last)
    if not rows:
        return 0
    sent = 0
    for row in rows:
        adif = adif_for_row(row)
        if adif is None:
            log("QSO rowid=%d no convertible a ADIF; lo salto" % row[0])
            write_last_rowid(row[0])
            continue
        try:
            answer = upload(api_key, adif)
        except Exception as e:
            log("error de red subiendo rowid=%d: %s" % (row[0], e))
            return sent
        if "RESULT=OK" in answer or "RESULT=REPLACE" in answer:
            write_last_rowid(row[0])
            sent += 1
            log("subido rowid=%d %s %s %s (%s)" % (row[0], row[6], row[5], row[4], answer.strip()[:120]))
        elif "RESULT=AUTH" in answer:
            # Key valida pero sin suscripcion QRZ (o sin permiso): no insistir cada 30 s.
            log("QRZ sin permiso para INSERT (suscripcion QRZ): %s; reintento en 1 h"
                % answer.strip()[:160])
            write_cooldown(3600)
            return sent
        else:
            log("QRZ rechazo rowid=%d: %s" % (row[0], answer.strip()[:200]))
            return sent
    return sent


def status(conf):
    print("config: %s" % CONF)
    print("  enabled=%s api_key=%s interval=%s" % (
        conf.get("enabled"), ("*" * 8 + conf["api_key"][-4:]) if conf.get("api_key") else "(vacío)",
        conf.get("interval")))
    print("estado: %s ultimo rowid=%d red=%s" % (STATE, read_last_rowid(), "up" if network_up() else "down"))
    rows = pending_rows(read_last_rowid())
    print("pendientes: %d" % len(rows))
    wait = read_cooldown()
    if wait > 0:
        print("cooldown: reintento en %d s (QRZ sin suscripcion)" % wait)
    if os.path.exists(LOG):
        print("ultimas lineas de %s:" % LOG)
        with open(LOG, errors="replace") as f:
            for line in f.readlines()[-10:]:
                print("  " + line.rstrip())


def dump_adif():
    rows = pending_rows(0)
    for row in rows:
        adif = adif_for_row(row)
        if adif is not None:
            print(adif)


def main():
    args = sys.argv[1:]
    once = "--once" in args
    loop = "--loop" in args
    do_status = "--status" in args
    do_adif = "--adif" in args
    conf = read_conf()
    if do_status:
        status(conf)
        return 0
    if do_adif:
        dump_adif()
        return 0
    enabled = conf.get("enabled", "1").lower() in ("1", "true", "yes", "si", "sí")
    if not enabled:
        log("deshabilitado por %s" % CONF)
        return 0
    if once:
        return 0 if run_once(conf) >= 0 else 1
    if not loop:
        print(__doc__)
        return 2
    try:
        interval = max(10, int(conf.get("interval", "30")))
    except ValueError:
        interval = 30
    while True:
        try:
            conf = read_conf()
        except Exception:
            pass
        try:
            run_once(conf)
        except Exception as e:  # el daemon no debe morir por un QSO raro
            log("excepcion: %s" % e)
        time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main())
