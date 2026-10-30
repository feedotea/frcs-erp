#!/usr/bin/env python3
"""
FRCS 收銀橋 —— 讓 FRCS INVENTORY 網頁可以印收據、開錢箱、印標籤

瀏覽器不能直接碰印表機，所以在收銀的 Mac 上跑這支。網頁只在 /ping 回得來時
才顯示「開錢箱」，iPad 或手機開網頁不會看到。

  GET  /ping    {"ok": true, "printer": true/false, "label": true/false}
  GET  /open    開錢箱（ESC p 脈衝，透過出單機 DK 孔）
  POST /print   JSON = 收據內容（index.html printReceipt 送的那包），kick:true 會順便開錢箱
  POST /label   JSON = {"items":[{"name","variant","no","price","qty"}]}  → TSPL 貼紙機

出單機 TP805 的接法（二選一，環境變數決定）：
  FRCS_PRINTER=192.168.1.60            網路孔，走 TCP 9100（建議；不用驅動）
  FRCS_SERIAL=/dev/tty.usbserial-XXXX  序列埠（USB 轉 RS-232），鮑率 FRCS_BAUD 預設 19200

貼紙機（TSPL 指令，Xprinter / Gprinter 那類）：
  FRCS_LABEL=192.168.1.61              網路；沒設就不開 /label
  FRCS_LABEL_SIZE=40x30                貼紙寬x高 mm

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
import sys
import time

PORT = int(os.environ.get('FRCS_BRIDGE_PORT', '9999'))
PRINTER = os.environ.get('FRCS_PRINTER', '')           # 出單機 IP
PRINTER_PORT = int(os.environ.get('FRCS_PRINTER_PORT', '9100'))
SERIAL = os.environ.get('FRCS_SERIAL', '')             # 或序列埠
BAUD = int(os.environ.get('FRCS_BAUD', '19200'))       # TP805 實測 19200，9600 是錯的
LABEL = os.environ.get('FRCS_LABEL', '')               # 貼紙機 IP
LABEL_PORT = int(os.environ.get('FRCS_LABEL_PORT', '9100'))
LABEL_SIZE = os.environ.get('FRCS_LABEL_SIZE', '40x30')
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


def label_up():
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
    w, h = (int(x) for x in LABEL_SIZE.lower().split('x'))
    dots = 8                                            # 203dpi ≈ 8 dots/mm
    out = b''
    for it in items:
        qty = max(1, int(it.get('qty', 1) or 1))
        name = str(it.get('name', ''))[:14]
        variant = str(it.get('variant', '') or '')
        no = str(it.get('no', ''))
        price = money(it.get('price', 0))
        cmd = f'SIZE {w} mm,{h} mm\nGAP 2 mm,0\nDIRECTION 1\nCLS\n'
        cmd += f'TEXT 16,12,"TSS24.BF2",0,1,1,"{name}"\n'
        if variant:
            cmd += f'TEXT 16,42,"TSS24.BF2",0,1,1,"{variant}"\n'
        bar_y = 72 if variant else 46
        cmd += f'BARCODE 16,{bar_y},"128",{max(40, h*dots - bar_y - 60)},1,0,2,2,"{no}"\n'
        cmd += f'TEXT 16,{h*dots - 34},"TSS24.BF2",0,1,1,"{price}"\n'
        cmd += f'PRINT 1,{qty}\n'
        out += cmd.encode(ENC)
    return out


def send_label(data):
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
            self.reply(200, {'ok': True, 'printer': printer_up(), 'label': label_up(), 'printerAddr': PRINTER or SERIAL or '', 'labelAddr': LABEL})
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
                if not LABEL:
                    self.reply(200, {'ok': False, 'message': '沒設貼紙機（FRCS_LABEL）'})
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
    print(f'FRCS bridge on http://127.0.0.1:{PORT}  ->  出單機 {how}  貼紙機 {LABEL or "未設定"} ({LABEL_SIZE})')
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
