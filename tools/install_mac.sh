#!/bin/bash
# DIM 收銀 Mac 一鍵安裝：抓橋接程式、找出單機 IP、設開機自動跑、印一張測試單
#   curl -fsSL https://raw.githubusercontent.com/feedotea/frcs-erp/main/tools/install_mac.sh | bash
#   也可以直接指定 IP：  ... | bash -s 192.168.1.60
set -e
BR="${FRCS_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/feedotea/frcs-erp/$BR/tools"
DIR="$HOME/frcs-bridge"
PLIST="$HOME/Library/LaunchAgents/com.frcs.bridge.plist"
mkdir -p "$DIR" "$HOME/Library/LaunchAgents"

echo "① 下載橋接程式…"
curl -fsSL "$RAW/frcs_bridge.py" -o "$DIR/frcs_bridge.py"

IP="${1:-}"
if [ -z "$IP" ]; then
  echo "② 在區網找出單機（9100 埠）…"
  IP=$(python3 - <<'EOF'
import socket, subprocess, re, concurrent.futures, sys, urllib.request
out=subprocess.run(['ifconfig'],capture_output=True,text=True).stdout
nets=set(re.findall(r'inet (\d+\.\d+\.\d+)\.\d+ ',out))-{'127.0.0'}
def chk(ip):
    try: socket.create_connection((ip,9100),timeout=0.4).close(); return ip
    except OSError: return None
hits=[]
for n in sorted(nets):
    with concurrent.futures.ThreadPoolExecutor(64) as ex:
        hits+=[r for r in ex.map(chk,[f'{n}.{i}' for i in range(1,255)]) if r]
def title(ip):
    try:
        html=urllib.request.urlopen(f'http://{ip}/',timeout=2).read(4000).decode('latin1')
        m=re.search(r'<title>([^<]*)',html,re.I); return (m.group(1).strip() if m else '有網頁')
    except Exception: return '（沒有網頁）'
info=[(ip,title(ip)) for ip in hits]
for ip,t in info: sys.stderr.write(f'   找到 {ip}  {t}\n')
good=[ip for ip,t in info if 'Star' not in t]
print(good[0] if len(good)==1 else '')
EOF
)
  if [ -z "$IP" ]; then
    echo "   沒有自動選到。請看上面列表，或在出單機上印自檢頁（關機、按住 FEED 開機）看 IP。"
    read -r -p "   出單機 IP：" IP </dev/tty
  else
    echo "   用 $IP"
  fi
fi

echo "③ 設定開機自動跑…"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.frcs.bridge</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>$DIR/frcs_bridge.py</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FRCS_PRINTER</key><string>$IP</string>
    <key>FRCS_LABEL</key><string></string>
    <key>FRCS_LABEL_SIZE</key><string>40x30</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/frcs_bridge.log</string>
  <key>StandardErrorPath</key><string>/tmp/frcs_bridge.log</string>
</dict>
</plist>
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2

echo "④ 檢查…"
PING=$(curl -s -m 3 http://127.0.0.1:9999/ping || true)
echo "   $PING"
case "$PING" in
  *'"printer": true'*)
    echo "⑤ 印測試單（錢箱會彈）…"
    curl -s -m 10 -X POST http://127.0.0.1:9999/print -H 'Content-Type: application/json' \
      -d '{"no":"TEST","datetime":"安裝測試","items":[{"name":"出單機連線測試","qty":1,"price":0}],"sub":0,"grand":0,"pay":"測試","footer":"DIM 安裝完成","kick":true}'
    echo
    echo "完成。iMac 開 https://feedotea.github.io/frcs-erp/ 登入，結帳頁會出現「開錢箱」。"
    ;;
  *'"ok": true'*)
    echo "橋接程式跑起來了，但連不到出單機 $IP。確認網路線有插、IP 對不對，再跑一次。"
    ;;
  *)
    echo "橋接程式沒起來，看 /tmp/frcs_bridge.log"
    ;;
esac
