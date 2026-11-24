#!/bin/zsh
# Installs and configures a local Mosquitto MQTT broker for JackeryBar (Homebrew).
# Creates user "jackery" with a random password, listens on port 1883 in your LAN,
# starts it as a background service and prints what to enter in the Jackery app.
set -euo pipefail

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
brew list mosquitto >/dev/null 2>&1 || brew install mosquitto

PREFIX=$(brew --prefix)
ETC=$PREFIX/etc/mosquitto
CONF=$ETC/mosquitto.conf
USER_NAME=${1:-jackery}
PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

if [[ -f $CONF ]] && ! grep -q "JackeryBar" $CONF; then
  cp $CONF $CONF.bak.$(date +%s)
  echo "Existing config backed up next to $CONF"
fi

cat > $CONF <<CONF
# Broker for Jackery SolarVault -> JackeryBar
listener 1883 0.0.0.0
allow_anonymous false
password_file $ETC/passwd
persistence false
log_dest stdout
CONF

rm -f $ETC/passwd
$PREFIX/opt/mosquitto/bin/mosquitto_passwd -b -c $ETC/passwd "$USER_NAME" "$PASS"
chmod 600 $ETC/passwd
brew services restart mosquitto >/dev/null

IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<your Mac IP>")
cat <<OUT

Mosquitto is running.

In the Jackery app (Device → Settings → MQTT) enter:
  Server IP : $IP
  Port      : 1883
  Username  : $USER_NAME
  Password  : $PASS

In JackeryBar → Settings use host 127.0.0.1 (or $IP), the same username/password,
plus the station serial number and the token shown by the Jackery app.
Tip: reserve $IP for this Mac in your router so the station always finds the broker.
OUT
