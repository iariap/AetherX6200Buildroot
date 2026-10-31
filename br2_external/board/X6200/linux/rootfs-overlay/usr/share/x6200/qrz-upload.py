#!/usr/bin/env python3
#
# X6200 — sube los QSO nuevos a los logs online cuando hay WiFi.
#
# Proveedores: QRZ Logbook, eQSL y Clublog (cada uno se habilita en /mnt/upload.conf).
#
# Uso:
#   qrz-upload.py --once     corre una pasada (para probar)
#   qrz-upload.py --loop     queda en bucle (lo arranca /etc/init.d/S55qrz-upload)
#   qrz-upload.py --status   muestra configuracion y estado sin subir nada
#   qrz-upload.py --adif     imprime el ADIF de todos los QSO del log (subida manual)
#
# Config: /mnt/upload.conf (se crea con la plantilla la primera vez)
# Estado: /mnt/<proveedor>_upload.state  (ultimo rowid subido con exito)
# Log:    /mnt/qrz-upload.log
#
# APIs (fundadas en la documentacion de cada servicio):
#  - QRZ:     POST https://logbook.qrz.com/api  KEY+ACTION=INSERT+ADIF (suscripcion
#             requerida por QRZ para INSERT; sin ella responde RESULT=AUTH)
#  - eQSL:    POST multipart https://www.eQSL.cc/qslcard/ImportADIF.cfm
#             campos Filename (ADIF), EQSL_USER, EQSL_PSWD
#             exito: "Result: x out of y records added" (o "Bad record: Duplicate")
#  - Clublog: POST multipart https://clublog.org/putlogs.php
#             campos file (ADIF), email, callsign, password (app password), api (API key)
#
# SPDX-License-Identifier: LGPL-2.1-or-later

import os
import sqlite3
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

CONF = os.environ.get("QRZ_CONF", "/mnt/upload.conf")
LEGACY_CONF = "/mnt/qrz.conf"
LOG = os.environ.get("QRZ_LOG", "/mnt/qrz-upload.log")
DB = os.environ.get("QRZ_DB", "/mnt/qso_log.db")
CA = os.environ.get("QRZ_CA", "/etc/ssl/certs/ca-certificates.crt")
WLAN = os.environ.get("QRZ_WLAN", "/sys/class/net/wlan0/operstate")

UA = "X6200-LogUpload/1.0 (LU2DSX)"
QRZ_API = "https://logbook.qrz.com/api"
EQSL_API = "https://www.eQSL.cc/qslcard/ImportADIF.cfm"
CL_API = "https://clublog.org/putlogs.php"

CONF_TEMPLATE = """# X6200 — subida automatica de QSO a logs online
# Habilita los proveedores que uses; sin credenciales no sube nada de ese proveedor.
enabled=1
interval=30

# QRZ Logbook (INSERT por API requiere suscripcion QRZ)
qrz_enabled=0
qrz_api_key=

# eQSL (gratis; usuario y clave de eqsl.cc)
eqsl_enabled=1
eqsl_user=
eqsl_pswd=

# Clublog (gratis; la API key y el "App password" se generan en clublog.org)
clublog_enabled=1
clublog_callsign=LU2DSX
clublog_email=
clublog_password=
clublog_api=
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
    """Devuelve dict con la config; migra /mnt/qrz.conf (v0.1.6) si existe."""
    if not os.path.exists(CONF):
        qrz_key = ""
        qrz_en = "0"
        if os.path.exists(LEGACY_CONF):
            try:
                with open(LEGACY_CONF) as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("api_key=") and line[8:]:
                            qrz_key = line[8:]
                        if line.startswith("enabled=") and line[8:]:
                            qrz_en = "1" if line[8:].strip() in ("1", "true", "yes") else "0"
            except OSError:
                pass
            try:
                os.replace(LEGACY_CONF, LEGACY_CONF + ".migrado")
            except OSError:
                pass
        txt = CONF_TEMPLATE.replace("qrz_enabled=0", "qrz_enabled=" + qrz_en)
        txt = txt.replace("qrz_api_key=\n", "qrz_api_key=%s\n" % qrz_key)
        try:
            with open(CONF, "w") as f:
                f.write(txt)
            os.chmod(CONF, 0o600)
            log("creada plantilla %s" % CONF)
        except OSError as e:
            log("no puedo crear %s: %s" % (CONF, e))
    conf = {"enabled": "1", "interval": "30"}
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


def cfg(conf, key, default=""):
    return conf.get(key, default).strip()


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "si", "sí", "on")


def network_up():
    try:
        with open(WLAN) as f:
            return f.read().strip() == "up"
    except OSError:
        return False


def state_path(prov):
    return os.environ.get("QRZ_STATE_" + prov.upper(), "/mnt/%s_upload.state" % prov)


def cooldown_path(prov):
    return "/mnt/%s_upload.cooldown" % prov


def read_last_rowid(prov):
    try:
        with open(state_path(prov)) as f:
            return int(f.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def write_last_rowid(prov, rowid):
    tmp = state_path(prov) + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(str(rowid))
        os.replace(tmp, state_path(prov))
    except OSError as e:
        log("no puedo escribir %s: %s" % (state_path(prov), e))


def read_cooldown(prov):
    try:
        with open(cooldown_path(prov)) as f:
            return max(0, int(f.read().strip() or "0") - int(time.time()))
    except (OSError, ValueError):
        return 0


def write_cooldown(prov, seconds):
    try:
        with open(cooldown_path(prov), "w") as f:
            f.write(str(int(time.time()) + seconds))
    except OSError as e:
        log("no puedo escribir %s: %s" % (cooldown_path(prov), e))


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


def adif_batch(rows):
    recs = [adif_for_row(r) for r in rows]
    recs = [r for r in recs if r]
    if not recs:
        return ""
    return "<adif_ver:5>3.1.0 <programid:8>X6200GUI <EOH>\n" + "\n".join(recs) + "\n"


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


def multipart(fields, filename, filecontent):
    boundary = "----X6200" + uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                 % (boundary, k, v)).encode()
    body += ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
             "Content-Type: text/plain\r\n\r\n" % (boundary, filename)).encode()
    body += filecontent.encode() + b"\r\n"
    body += ("--%s--\r\n" % boundary).encode()
    return body, "multipart/form-data; boundary=" + boundary


def http_post(url, body, content_type, headers=None):
    h = {"User-Agent": UA, "Content-Type": content_type}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=body, method="POST", headers=h)
    ctx = ssl.create_default_context(cafile=CA if os.path.exists(CA) else None)
    with urllib.request.urlopen(req, timeout=45, context=ctx) as resp:
        return resp.read().decode("utf-8", "replace")


# --- proveedores -----------------------------------------------------------

def upload_qrz(conf, rows, adif):
    api_key = cfg(conf, "qrz_api_key")
    if not api_key:
        return None, "sin qrz_api_key"
    body = urllib.parse.urlencode({"KEY": api_key, "ACTION": "INSERT", "ADIF": adif}).encode()
    answer = http_post(QRZ_API, body, "application/x-www-form-urlencoded")
    if "RESULT=OK" in answer or "RESULT=REPLACE" in answer:
        return True, answer.strip()[:160]
    if "RESULT=AUTH" in answer:
        return "auth", answer.strip()[:200]
    return False, answer.strip()[:200]


def upload_eqsl(conf, rows, adif):
    user = cfg(conf, "eqsl_user")
    pswd = cfg(conf, "eqsl_pswd")
    if not user or not pswd:
        return None, "sin eqsl_user/eqsl_pswd"
    # Metodo documentado en ImportADIF.txt: form con ADIFData + EQSL_USER + EQSL_PSWD.
    body = urllib.parse.urlencode({"EQSL_USER": user, "EQSL_PSWD": pswd,
                                   "ADIFData": adif}).encode()
    answer = http_post(EQSL_API, body, "application/x-www-form-urlencoded")
    flat = " ".join(answer.replace("\r", " ").split())
    if "records added" in flat or "Bad record: Duplicate" in flat:
        return True, flat[:200]
    low = flat.lower()
    if "no match on eqsl_user" in low or "missing eqsl_user" in low or "missing eqsl_pswd" in low:
        return "auth", flat[:200]
    if "error:" in low:
        return False, flat[:200]
    return False, flat[:200]


def upload_clublog(conf, rows, adif):
    # Medido 27/10 desde la red del proyecto: https://clublog.org/putlogs.php responde
    # 403 Forbidden de nginx incluso para un GET (otras paginas del sitio dan 200),
    # asi que puede ser un bloqueo por red/region. Se implementa igual segun la guia
    # (multipart: file/email/callsign/password/api) y el 403 se trata como auth para
    # no insistir: el daemon reintenta en 1 h.
    email = cfg(conf, "clublog_email")
    callsign = cfg(conf, "clublog_callsign")
    pswd = cfg(conf, "clublog_password")
    api = cfg(conf, "clublog_api")
    if not (email and callsign and pswd and api):
        return None, "faltan clublog_email/callsign/password/api"
    body, ctype = multipart({"email": email, "callsign": callsign,
                             "password": pswd, "api": api}, "qso.adi", adif)
    try:
        answer = http_post(CL_API, body, ctype)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            return "auth", "HTTP %d (Clublog bloquea esta red o credenciales)" % e.code
        raise
    low = answer.lower()
    if "invalid api key" in low or "login" in low or "password" in low or "not found" in low:
        return "auth", answer.replace("\r", " ")[:200]
    if "error" in low:
        return False, answer.replace("\r", " ")[:200]
    return True, answer.replace("\r", " ")[:160]


PROVIDERS = [
    ("qrz", "qrz_enabled", upload_qrz),
    ("eqsl", "eqsl_enabled", upload_eqsl),
    ("clublog", "clublog_enabled", upload_clublog),
]


def run_provider(conf, prov, enabled_key, fn):
    if not truthy(cfg(conf, enabled_key, "0")):
        return None
    wait = read_cooldown(prov)
    if wait > 0:
        return None
    last = read_last_rowid(prov)
    rows = pending_rows(last)
    if not rows:
        return 0
    adif = adif_batch(rows)
    if not adif:
        return 0
    try:
        ok, msg = fn(conf, rows, adif)
    except urllib.error.HTTPError as e:
        log("%s: HTTP %d de red: %s; reintento en 1 h" % (prov, e.code, e.reason))
        if e.code in (401, 403):
            write_cooldown(prov, 3600)
        return 0
    except Exception as e:
        log("%s: error de red: %s" % (prov, e))
        return 0
    if ok is None:
        return None  # sin credenciales: silencio
    if ok == "auth":
        log("%s sin permiso/credenciales: %s; reintento en 1 h" % (prov, msg))
        write_cooldown(prov, 3600)
        return 0
    if ok:
        write_last_rowid(prov, rows[-1][0])
        log("%s: subidos %d QSO (rowid<=%d): %s" % (prov, len(rows), rows[-1][0], msg))
        return len(rows)
    log("%s rechazo (rowid=%d): %s" % (prov, rows[0][0], msg))
    return 0


def run_once(conf):
    sent = 0
    for prov, key, fn in PROVIDERS:
        try:
            n = run_provider(conf, prov, key, fn)
            if n:
                sent += n
        except Exception as e:
            log("%s: excepcion: %s" % (prov, e))
    return sent


def status(conf):
    print("config: %s" % CONF)
    print("  enabled=%s interval=%s" % (cfg(conf, "enabled"), cfg(conf, "interval")))
    for prov, key, _ in PROVIDERS:
        state = "off"
        if truthy(cfg(conf, key, "0")):
            state = "on"
        last = read_last_rowid(prov)
        pend = len(pending_rows(last))
        cool = read_cooldown(prov)
        extra = ""
        if cool:
            extra = " cooldown=%d s" % cool
        print("  %-8s %-3s ultimo_rowid=%-3d pendientes=%-3d%s" % (prov, state, last, pend, extra))
    if os.path.exists(LOG):
        print("ultimas lineas de %s:" % LOG)
        with open(LOG, errors="replace") as f:
            for line in f.readlines()[-12:]:
                print("  " + line.rstrip())


def dump_adif():
    rows = pending_rows(0)
    adif = adif_batch(rows)
    if adif:
        print(adif, end="")


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
    if not truthy(cfg(conf, "enabled", "1")):
        log("deshabilitado por %s" % CONF)
        return 0
    if once:
        run_once(conf)
        return 0
    if not loop:
        print(__doc__)
        return 2
    try:
        interval = max(10, int(cfg(conf, "interval", "30")))
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
