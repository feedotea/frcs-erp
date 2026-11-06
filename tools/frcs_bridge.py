#!/usr/bin/env python3
"""
FRCS 收銀橋 —— 讓 FRCS INVENTORY 網頁可以印收據、開錢箱、印標籤

瀏覽器不能直接碰印表機，所以在收銀的 Mac 上跑這支。網頁只在 /ping 回得來時
才顯示「開錢箱」，iPad 或手機開網頁不會看到。

  GET  /ping    {"ok": true, "printer": true/false, "label": true/false}
  GET  /open    開錢箱（ESC p 脈衝，透過出單機 DK 孔）
  POST /print   JSON = 收據內容（index.html printReceipt 送的那包），kick:true 會順便開錢箱
  POST /label   JSON = {"items":[{"name","variant","no","price","qty"}]}  → TSPL 貼紙機
  GET  /calibrate 貼紙機重新偵測間隙（換紙後印歪、疊印時用）

出單機 TP805 的接法（二選一，環境變數決定）：
  FRCS_PRINTER=192.168.1.60            網路孔，走 TCP 9100（建議；不用驅動）
  FRCS_SERIAL=/dev/tty.usbserial-XXXX  序列埠（USB 轉 RS-232），鮑率 FRCS_BAUD 預設 19200

貼紙機（TSPL 指令，Xprinter / Gprinter 那類），二選一：
  FRCS_LABEL=192.168.1.61              網路版，走 TCP 9100
  FRCS_LABEL_QUEUE=dimlabel            USB 版，插 Mac，透過 CUPS 列印佇列 raw 送（install_label_mac.sh 會建）
  FRCS_LABEL_SIZE=40x30                貼紙寬x高 mm
  FRCS_LABEL_ENC=gb18030               貼紙機中文編碼（XP-420B 是 GBK；出單機 TP805 是 Big5，兩台不一樣）
  FRCS_LABEL_TOP=12                    上邊留白點數
  FRCS_LABEL_TEAR=ON  FRCS_LABEL_DIR=1  FRCS_LABEL_SHIFT=0   印出來偏掉時調（GET /labeltest 印診斷頁）

執行：
  python3 tools/frcs_bridge.py
  FRCS_PRINTER=192.168.1.60 python3 tools/frcs_bridge.py

只綁 127.0.0.1：同一台電腦上的瀏覽器才叫得到。CORS 只放行 FRCS 的站台。
中文用 Big5（cp950）送：自檢頁 Traditional Character Mode: YES。收據寬 80mm = 48 個半形字。
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

PORT = int(os.environ.get('FRCS_BRIDGE_PORT', '9999'))
PRINTER = os.environ.get('FRCS_PRINTER', '')           # 出單機 IP
PRINTER_PORT = int(os.environ.get('FRCS_PRINTER_PORT', '9100'))
SERIAL = os.environ.get('FRCS_SERIAL', '')             # 或序列埠
BAUD = int(os.environ.get('FRCS_BAUD', '19200'))       # TP805 實測 19200，9600 是錯的
LABEL = os.environ.get('FRCS_LABEL', '')               # 貼紙機 IP（網路版）
LABEL_QUEUE = os.environ.get('FRCS_LABEL_QUEUE', '')   # 或 CUPS 佇列名（USB 版）
LABEL_PORT = int(os.environ.get('FRCS_LABEL_PORT', '9100'))
LABEL_SIZE = os.environ.get('FRCS_LABEL_SIZE', '40x30')
LABEL_ENC = os.environ.get('FRCS_LABEL_ENC', 'gb18030')  # XP-420B 內建中文字庫是 GBK：Big5 送過去「黑」會變「堵」
LABEL_TOP = int(os.environ.get('FRCS_LABEL_TOP', '12'))  # 上邊留白（點）
LABEL_TEAR = os.environ.get('FRCS_LABEL_TEAR', 'ON').upper()   # 撕紙模式 ON/OFF：印完要不要把貼紙送到撕紙口
LABEL_DIR = os.environ.get('FRCS_LABEL_DIR', '1')              # 列印方向 0/1
LABEL_SHIFT = int(os.environ.get('FRCS_LABEL_SHIFT', '0'))     # 整張圖垂直位移（點），印出來偏就調這個
ENC = 'cp950'                                           # TP805 自檢頁 Traditional Character Mode: YES → Big5
COLS = 48                                               # 80mm 紙、Font A 每行字數

ORIGINS = {
    'https://feedotea.github.io',
    'http://localhost:8160',
    'http://127.0.0.1:8160',
    'null',                                             # 直接開 file:// 時
}

ESC, GS, FS = b'\x1b', b'\x1d', b'\x1c'
INIT = ESC + b'@' + FS + b'&'                           # 初始化 + 進中文模式
CUT = GS + b'V\x42\x00'                                 # 走紙後切紙
KICK = ESC + b'p\x00\x19\xfa'                           # DK 脈衝 50ms / 500ms
ALIGN = {'l': ESC + b'a\x00', 'c': ESC + b'a\x01', 'r': ESC + b'a\x02'}
BOLD_ON, BOLD_OFF = ESC + b'E\x01', ESC + b'E\x00'
BIG_ON, BIG_OFF = GS + b'!\x11', GS + b'!\x00'


# ---------------- 送到出單機 ----------------
def send_printer(data):
    if PRINTER:
        with socket.create_connection((PRINTER, PRINTER_PORT), timeout=10) as s:
            s.sendall(data)
        return
    if SERIAL:
        try:
            import serial  # pyserial；pip3 install pyserial
        except ImportError:
            raise RuntimeError('序列埠模式需要 pyserial：pip3 install pyserial')
        with serial.Serial(SERIAL, BAUD, timeout=3) as p:
            p.write(data)
            p.flush()
            time.sleep(0.2)
        return
    raise RuntimeError('沒設 FRCS_PRINTER 或 FRCS_SERIAL')


def printer_up():
    try:
        if PRINTER:
            socket.create_connection((PRINTER, PRINTER_PORT), timeout=1.5).close()
            return True
        if SERIAL:
            return os.path.exists(SERIAL)
    except Exception:          # 連 IP 填錯成亂字（UnicodeError）都要吞掉，/ping 不能掛
        pass
    return False


def queue_revive():
    """貼紙機關機時有人按列印，CUPS 會把佇列標成暫停、工作卡住；印之前先解除、清掉舊工作。"""
    for cmd in (['cupsenable', LABEL_QUEUE], ['cupsaccept', LABEL_QUEUE], ['cancel', '-a', LABEL_QUEUE]):
        try:
            subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        except Exception:
            pass


def label_up():
    if LABEL_QUEUE:
        try:
            r = subprocess.run(['lpstat', '-p', LABEL_QUEUE], capture_output=True, text=True, timeout=5)
            if r.returncode != 0:
                return False
            if 'disabled' in r.stdout or 'Paused' in r.stdout:
                queue_revive()
                r = subprocess.run(['lpstat', '-p', LABEL_QUEUE], capture_output=True, text=True, timeout=5)
            return r.returncode == 0 and 'disabled' not in r.stdout
        except Exception:
            return False
    if not LABEL:
        return False
    try:
        socket.create_connection((LABEL, LABEL_PORT), timeout=1.5).close()
        return True
    except Exception:
        return False


# ---------------- 收據排版 ----------------
def width(s):
    """半形算 1、全形算 2"""
    return sum(2 if ord(ch) > 0x2e80 else 1 for ch in s)


def lr(left, right):
    """左右對齊一行；左邊太長就截"""
    right = str(right)
    room = COLS - width(right) - 1
    while width(left) > room:
        left = left[:-1]
    return left + ' ' * (COLS - width(left) - width(right)) + right + '\n'


def money(n):
    try:
        return 'NT$' + format(int(round(float(n))), ',')
    except (TypeError, ValueError):
        return 'NT$0'


def receipt_bytes(p):
    out = INIT
    out += ALIGN['c'] + BIG_ON + BOLD_ON + 'DIM\n'.encode(ENC) + BIG_OFF + BOLD_OFF
    out += 'For Restless City Souls\nTainan\n'.encode(ENC)
    out += ('-' * COLS + '\n').encode(ENC)
    out += ALIGN['l']
    out += lr('單號 ' + str(p.get('no', '')), '').encode(ENC)
    out += (str(p.get('datetime', '')) + '\n').encode(ENC)
    if p.get('member'):
        out += ('會員 ' + str(p['member']) + '\n').encode(ENC)
    out += ('-' * COLS + '\n').encode(ENC)
    for it in p.get('items', []):
        qty = int(it.get('qty', 1) or 1)
        line_total = float(it.get('price', 0) or 0) * qty
        out += lr(f"{it.get('name','')} x{qty}", format(int(round(line_total)), ',')).encode(ENC)
    out += ('-' * COLS + '\n').encode(ENC)
    out += lr('小計', money(p.get('sub', 0))).encode(ENC)
    if p.get('memOff'):
        out += lr('會員折扣', '-' + format(int(p['memOff']), ',')).encode(ENC)
    if p.get('manOff'):
        out += lr('折扣', '-' + format(int(p['manOff']), ',')).encode(ENC)
    out += BOLD_ON + lr('應收', money(p.get('grand', 0))).encode(ENC) + BOLD_OFF
    out += lr('付款', str(p.get('pay', ''))).encode(ENC)
    if p.get('cash'):
        out += lr('收現', money(p['cash'])).encode(ENC)
        out += lr('找零', money(p.get('change', 0))).encode(ENC)
    out += ('-' * COLS + '\n').encode(ENC)
    out += ALIGN['c'] + (str(p.get('footer', '謝謝惠顧 · DIM')) + '\n').encode(ENC)
    out += b'\n\n\n' + CUT
    if p.get('kick'):
        out += KICK
    return out


# ---------------- 標籤（TSPL） ----------------
def label_bytes(items):
    """40x30 版面（203dpi，8 點/mm，共 320x240 點）：
         品名
         顏色 / 尺寸          ← 沒有規格就略過，下面往上收
         ▌▌▌ 條碼 ▌▌▌  （條碼下面印數字）
         NT$1,480
       全部往下推 LABEL_TOP 點，因為實機第一行會被切掉。"""
    w, h = (int(x) for x in LABEL_SIZE.lower().split('x'))
    dots = 8
    H = h * dots
    out = b''
    for it in items:
        qty = max(1, int(it.get('qty', 1) or 1))
        name = str(it.get('name', ''))[:14]
        variant = str(it.get('variant', '') or '')
        no = str(it.get('no', ''))
        price = money(it.get('price', 0))
        y = LABEL_TOP
        cmd = label_head(w, h)
        cmd += f'TEXT 16,{y},"TSS24.BF2",0,1,1,"{name}"\n'
        y += 26
        if variant:
            cmd += f'TEXT 16,{y},"TSS24.BF2",0,1,1,"{variant}"\n'
            y += 26
        price_y = H - 30                              # 價格貼底
        bar_h = max(40, price_y - y - 30)             # 條碼高度：剩下的空間扣掉底下數字那行
        if no.isascii() and no.strip():
            cmd += f'BARCODE 16,{y},"128",{bar_h},1,0,2,2,"{no}"\n'
        else:
            # 編號含中文印不成條碼（機器只會印一個 ?），改印提示，請老闆把編號改成數字
            cmd += f'TEXT 16,{y},"TSS24.BF2",0,1,1,"編號非數字:{no[:10]}"\n'
            cmd += f'TEXT 16,{y+28},"TSS24.BF2",0,1,1,"請改編號再印"\n'
        cmd += f'TEXT 16,{price_y},"TSS24.BF2",0,1,1,"{price}"\n'
        cmd += f'PRINT 1,{qty}\n'
        out += cmd.encode(LABEL_ENC, errors='replace')
    return out


def label_head(w, h):
    return (f'SIZE {w} mm,{h} mm\nGAP 2 mm,0\nSET TEAR {LABEL_TEAR}\nDIRECTION {LABEL_DIR}\n'
            f'REFERENCE 0,0\nSHIFT {LABEL_SHIFT}\nCLS\n')


def labeltest_bytes():
    """診斷頁：三張不同設定，每張印外框＋代號，看哪張外框貼齊貼紙邊。"""
    w, h = (int(x) for x in LABEL_SIZE.lower().split('x'))
    W, H = w * 8, h * 8
    out = b''
    for code, tear, d in (('A', 'ON', '1'), ('B', 'OFF', '1'), ('C', 'ON', '0')):
        cmd = (f'SIZE {w} mm,{h} mm\nGAP 2 mm,0\nSET TEAR {tear}\nDIRECTION {d}\nREFERENCE 0,0\nSHIFT 0\nCLS\n'
               f'BOX 2,2,{W-3},{H-3},3\n'
               f'TEXT 16,16,"3",0,2,2,"{code}"\n'
               f'TEXT 80,24,"2",0,1,1,"TEAR {tear} DIR {d}"\n'
               f'TEXT 16,{H-40},"2",0,1,1,"bottom {code}"\n'
               f'PRINT 1,1\n')
        out += cmd.encode('ascii')
    return out


def calibrate_bytes():
    """讓貼紙機重新偵測貼紙間隙。換紙、開蓋後要做一次，不然會印在同一張上或位置偏掉。"""
    w, h = (int(x) for x in LABEL_SIZE.lower().split('x'))
    return f'SIZE {w} mm,{h} mm\nGAP 2 mm,0\nGAPDETECT\nSET TEAR ON\n'.encode('ascii')


def send_label(data):
    if LABEL_QUEUE:
        # USB：丟給 CUPS 佇列，-o raw 不經任何轉換，TSPL 原樣進印表機
        queue_revive()
        with tempfile.NamedTemporaryFile('wb', suffix='.tspl', delete=False) as f:
            f.write(data)
            path = f.name
        try:
            r = subprocess.run(['lp', '-d', LABEL_QUEUE, '-o', 'raw', path], capture_output=True, text=True, timeout=20)
            if r.returncode != 0:
                raise RuntimeError('lp 失敗：' + (r.stderr or r.stdout).strip())
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        return
    with socket.create_connection((LABEL, LABEL_PORT), timeout=10) as s:
        s.sendall(data)


# ---------------- HTTP ----------------
class H(http.server.BaseHTTPRequestHandler):
    def cors(self):
        o = self.headers.get('Origin', '')
        if o in ORIGINS or o.startswith('http://localhost') or o.startswith('http://127.0.0.1'):
            self.send_header('Access-Control-Allow-Origin', o)
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.send_header('Access-Control-Allow-Private-Network', 'true')

    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.cors()
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/ping':
            self.reply(200, {'ok': True, 'printer': printer_up(), 'label': label_up(), 'printerAddr': PRINTER or SERIAL or '', 'labelAddr': LABEL or LABEL_QUEUE})
        elif path == '/labeltest':
            try:
                send_label(labeltest_bytes())
                self.reply(200, {'ok': True})
            except Exception as e:
                self.reply(200, {'ok': False, 'message': str(e)})
        elif path == '/calibrate':
            try:
                if not (LABEL or LABEL_QUEUE):
                    raise RuntimeError('沒設貼紙機')
                send_label(calibrate_bytes())
                self.reply(200, {'ok': True})
            except Exception as e:
                self.reply(200, {'ok': False, 'message': str(e)})
        elif path == '/open':
            try:
                send_printer(INIT + KICK)
                self.reply(200, {'ok': True})
            except Exception as e:
                self.reply(200, {'ok': False, 'message': str(e)})
        else:
            self.reply(404, {'ok': False, 'message': 'not found'})

    def do_POST(self):
        path = self.path.split('?')[0]
        n = int(self.headers.get('Content-Length', '0') or 0)
        try:
            payload = json.loads(self.rfile.read(n).decode('utf-8') or '{}')
        except ValueError:
            self.reply(400, {'ok': False, 'message': 'bad json'})
            return
        try:
            if path == '/print':
                send_printer(receipt_bytes(payload))
                self.reply(200, {'ok': True})
            elif path == '/label':
                if not LABEL and not LABEL_QUEUE:
                    self.reply(200, {'ok': False, 'message': '沒設貼紙機（FRCS_LABEL 或 FRCS_LABEL_QUEUE）'})
                    return
                items = payload.get('items', [])
                if not items:
                    self.reply(400, {'ok': False, 'message': 'no items'})
                    return
                send_label(label_bytes(items))
                self.reply(200, {'ok': True, 'count': sum(int(i.get('qty', 1) or 1) for i in items)})
            else:
                self.reply(404, {'ok': False, 'message': 'not found'})
        except Exception as e:
            self.reply(200, {'ok': False, 'message': str(e)})

    def log_message(self, fmt, *args):
        sys.stderr.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % args))


if __name__ == '__main__':
    how = f'{PRINTER}:{PRINTER_PORT}' if PRINTER else (f'{SERIAL} @ {BAUD}' if SERIAL else '未設定')
    print(f'FRCS bridge on http://127.0.0.1:{PORT}  ->  出單機 {how}  貼紙機 {LABEL or LABEL_QUEUE or "未設定"} ({LABEL_SIZE})')
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
