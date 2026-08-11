#!/bin/sh
# Keep qBittorrent's listening port equal to PIA's forwarded port.
#
# Runs in gluetun's network namespace (see the qbittorrent-port-sync service in
# compose.yaml), so both endpoints are on localhost: gluetun's control server on
# :8000, qBittorrent's WebUI on :8080. It reads the forwarded port from
# /v1/portforward and, on a change, pushes it into qBittorrent via setPreferences.
#
# qBittorrent must have "bypass authentication for clients on localhost" on for
# the unauthenticated call to be accepted. Until it is, setPreferences returns
# an error and this loop retries without doing harm, so the ordering between
# this and qBittorrent coming up does not matter.
set -u

last=""
while true; do
  port=$(curl -fsS --max-time 5 http://localhost:8000/v1/portforward 2>/dev/null \
         | sed -n 's/.*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p')

  if [ -n "$port" ] && [ "$port" != "$last" ]; then
    if curl -fsS --max-time 5 \
         -H "Referer: http://localhost:8080" \
         --data-urlencode "json={\"listen_port\": $port, \"random_port\": false, \"upnp\": false}" \
         http://localhost:8080/api/v2/app/setPreferences >/dev/null 2>&1; then
      echo "[qbit-port-sync] set listen_port=$port"
      last="$port"
    else
      echo "[qbit-port-sync] qBittorrent not ready for port=$port, will retry"
    fi
  fi

  sleep 30
done
