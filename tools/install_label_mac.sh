#!/bin/bash
# DIM 貼紙機（USB 版 Xprinter）一鍵接上 Mac：建 raw 列印佇列、告訴橋接程式、印一張測試貼紙
#   curl -fsSL https://raw.githubusercontent.com/feedotea/frcs-erp/main/tools/install_label_mac.sh | bash
#   指定貼紙尺寸：  ... | bash -s 40x30
# 前提：貼紙機 USB 線插 Mac、電源開、貼紙裝好；橋接程式已經用 install_mac.sh 裝過。
set -e
SIZE="${1:-40x30}"
QUEUE="dimlabel"
PLIST="$HOME/Library/LaunchAgents/com.frcs.bridge.plist"

echo "① 找 USB 貼紙機…"
URI=$(lpinfo -v 2>/dev/null | awk '/^direct usb:/ {print $2}' | grep -i -E 'xprinter|xp-|gprinter|label|tspl|4[0-9]{2}B' | head -1 || true)
if [ -z "$URI" ]; then
  URI=$(lpinfo -v 2>/dev/null | awk '/^direct usb:/ {print $2}' | head -1 || true)
fi
if [ -z "$URI" ]; then
  echo "   找不到 USB 印表機。確認 USB 線插好、電源開著，再跑一次。"
  echo "   （lpinfo -v 看到的：）"; lpinfo -v 2>/dev/null | sed 's/^/   /'
  exit 1
fi
echo "   用 $URI"

echo "② 建列印佇列 $QUEUE（raw，不經驅動）…"
lpadmin -x "$QUEUE" 2>/dev/null || true
if ! lpadmin -p "$QUEUE" -E -v "$URI" -m raw 2>/dev/null; then
  # 新版 macOS 不給 -m raw：用 everywhere 建，lp -o raw 一樣可以直送
  lpadmin -p "$QUEUE" -E -v "$URI" -m everywhere 2>/dev/null || lpadmin -p "$QUEUE" -E -v "$URI"
fi
cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true
lpstat -p "$QUEUE" | sed 's/^/   /'

echo "③ 告訴橋接程式…"
if [ ! -f "$PLIST" ]; then
  echo "   還沒裝橋接程式，先跑 install_mac.sh"; exit 1
fi
python3 - "$PLIST" "$QUEUE" "$SIZE" <<'EOF'
import plistlib, sys
p, q, size = sys.argv[1], sys.argv[2], sys.argv[3]
d = plistlib.load(open(p, 'rb'))
env = d.setdefault('EnvironmentVariables', {})
env['FRCS_LABEL_QUEUE'] = q
env['FRCS_LABEL'] = ''
env['FRCS_LABEL_SIZE'] = size
plistlib.dump(d, open(p, 'wb'))
print('   plist 已更新：FRCS_LABEL_QUEUE=%s FRCS_LABEL_SIZE=%s' % (q, size))
EOF
curl -fsSL "https://raw.githubusercontent.com/feedotea/frcs-erp/${FRCS_BRANCH:-main}/tools/frcs_bridge.py" -o "$HOME/frcs-bridge/frcs_bridge.py"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 2

echo "④ 檢查…"
PING=$(curl -s -m 3 http://127.0.0.1:9999/ping || true)
echo "   $PING"
case "$PING" in
  *'"label": true'*)
    echo "⑤ 校正貼紙間隙（會走幾張空白紙，正常）…"
    curl -s -m 20 http://127.0.0.1:9999/calibrate; echo
    sleep 4
    echo "⑥ 印一張測試貼紙…"
    curl -s -m 20 -X POST http://127.0.0.1:9999/label -H 'Content-Type: application/json' \
      -d '{"items":[{"name":"測試商品","variant":"黑 / M","no":"2149701","price":1480,"qty":1}]}'
    echo
    echo "完成。網頁重新整理，商品庫存 → 標籤 會顯示「已接貼紙機」。"
    ;;
  *)
    echo "橋接程式起來了但看不到貼紙機佇列。看 lpstat -p $QUEUE 和 /tmp/frcs_bridge.log"
    ;;
esac
