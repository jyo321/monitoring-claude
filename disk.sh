```bash
#!/bin/bash

# MonitoringHub Disk Monitoring Agent (No Authentication)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/app.config"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: app.config not found at ${CONFIG_FILE}" >&2
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$API_URL" ]; then
    echo "ERROR: API_URL must be set in app.config" >&2
    exit 1
fi

LOG_FILE="${LOG_FILE:-/tmp/disk-monitor.log}"
MAX_RETRIES="${MAX_RETRIES:-3}"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

# Verify curl exists
command -v curl >/dev/null 2>&1 || {
    log "ERROR: curl not installed"
    exit 1
}

HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

collect_disks() {

    ROOT_LINE=$(df -hPT / | awk 'NR==2')

    ROOT_TOTAL=$(echo "$ROOT_LINE" | awk '{print $3}')
    ROOT_USED=$(echo "$ROOT_LINE" | awk '{print $4}')
    ROOT_AVAIL=$(echo "$ROOT_LINE" | awk '{print $5}')
    ROOT_PCT=$(echo "$ROOT_LINE" | awk '{print $6}' | tr -d '%')
    ROOT_FSTYPE=$(echo "$ROOT_LINE" | awk '{print $2}')

    echo "/|/dev/root|${ROOT_FSTYPE}|${ROOT_TOTAL}|${ROOT_USED}|${ROOT_AVAIL}|${ROOT_PCT}"

    df -hPT \
        -x tmpfs \
        -x devtmpfs \
        -x squashfs |
    awk 'NR>1' |
    while read -r FILESYSTEM FSTYPE TOTAL USED AVAILABLE USAGE MOUNTPOINT
    do
        [ "$MOUNTPOINT" = "/" ] && continue

        echo "$FILESYSTEM" | grep -Eq "loop|snap" && continue

        USAGE=$(echo "$USAGE" | tr -d '%')

        echo "${MOUNTPOINT}|${FILESYSTEM}|${FSTYPE}|${TOTAL}|${USED}|${AVAILABLE}|${USAGE}"
    done
}

DISKS_JSON="["
FIRST=1

while IFS='|' read -r MOUNT FILESYSTEM FSTYPE TOTAL USED AVAIL PCT
do
    [ -z "$MOUNT" ] && continue

    [ "$FIRST" -eq 0 ] && DISKS_JSON+=","
    FIRST=0

    DISKS_JSON+=$(printf \
        '{"mountPoint":"%s","filesystem":"%s","fileSystemType":"%s","totalSize":"%s","usedSize":"%s","availableSize":"%s","usagePercent":%s}' \
        "$MOUNT" "$FILESYSTEM" "$FSTYPE" "$TOTAL" "$USED" "$AVAIL" "$PCT")

done < <(collect_disks)

DISKS_JSON+="]"

PAYLOAD=$(printf \
    '{"hostname":"%s","ipAddress":"%s","timestamp":"%s","disks":%s}' \
    "$HOSTNAME_VAL" \
    "$IP_ADDRESS" \
    "$TIMESTAMP" \
    "$DISKS_JSON")

log "Sending metrics for ${HOSTNAME_VAL} (${IP_ADDRESS}) → ${API_URL}/api/metrics/disk"

for attempt in $(seq 1 "$MAX_RETRIES")
do
    RESP_FILE=$(mktemp)

    HTTP_STATUS=$(curl -s \
        -o "$RESP_FILE" \
        -w "%{http_code}" \
        -X POST "${API_URL}/api/metrics/disk" \
        -H "Content-Type: application/json" \
        --connect-timeout 10 \
        --max-time 30 \
        -d "$PAYLOAD")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
        log "SUCCESS attempt=${attempt} status=${HTTP_STATUS}"
        rm -f "$RESP_FILE"
        exit 0
    fi

    log "FAILED attempt=${attempt} status=${HTTP_STATUS} body=$(cat "$RESP_FILE")"

    rm -f "$RESP_FILE"

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        sleep $((attempt * 5))
    fi
done

log "GAVE UP after ${MAX_RETRIES} attempts — check ${API_URL} is reachable"

exit 1
```
