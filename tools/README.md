# 收銀 Mac 的橋接程式

`frcs_bridge.py` 跑在收銀的 Mac 上，讓網頁能印收據、開錢箱、印標籤。
macOS 內建 python3，不用另外裝東西（序列埠模式才要 `pip3 install pyserial`）。

## 硬體

| 設備 | 接法 |
|---|---|
| 出單機 TP805 | 背面有網路孔：網路線接路由器，設固定 IP（例如 192.168.1.60），走 TCP 9100。不用驅動。 |
| 錢箱 | RJ11 線接出單機背面 **DK** 孔，24V 由出單機供。開錢箱是透過出單機下指令。 |
| 貼紙機 | 待確認型號。吃 TSPL 指令的網路貼紙機（Xprinter、Gprinter）可直接用。 |

序列埠備案：如果不想拉網路線，用 USB 轉 RS-232（挑 FTDI 晶片），
`FRCS_SERIAL=/dev/tty.usbserial-XXXX FRCS_BAUD=19200`。TP805 實測 19200，9600 是錯的。

## 出單機設固定 IP

1. 關機，按住 FEED 不放再開機，印出自檢頁，上面有目前 IP。
2. 瀏覽器開 `http://<那個 IP>/`，把 IP 改成 192.168.1.60（跟路由器同網段、避開 DHCP 範圍）。
3. 改完 `nc -z 192.168.1.60 9100 && echo ok` 看得到 ok 就通了。

## 手動跑一次

```bash
FRCS_PRINTER=192.168.1.60 python3 ~/frcs-erp/tools/frcs_bridge.py
```

然後在同一台 Mac 開 https://feedotea.github.io/frcs-erp/ ，結帳頁會多出「開錢箱」按鈕。
帳務 → 開銷頁底「雲端連線設定」裡「收銀主機位址」保持 `http://localhost:9999`。

## 開機自動跑（launchd）

把 `com.frcs.bridge.plist` 裡的 IP 改好，然後：

```bash
cp ~/frcs-erp/tools/com.frcs.bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.frcs.bridge.plist
```

之後每次登入自動啟動、掛掉自動重開。log 在 `/tmp/frcs_bridge.log`。
要停：`launchctl unload ~/Library/LaunchAgents/com.frcs.bridge.plist`。

## 網頁怎麼用它

- 結帳收現金：收據和開錢箱指令一起送，彈一次。
- 不印收據的現金單：只開錢箱。
- 標籤頁：橋接程式有接貼紙機時，每項可填張數，按列印直接出貼紙；沒接就退回瀏覽器列印。
