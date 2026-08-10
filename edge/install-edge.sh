#!/usr/bin/env bash
if [ "$(id -u)" -ne 0 ]; then echo "Run as root." >&2; exit 1; fi
if [ ! -r "$0" ] || [ "$(head -n 1 "$0" 2>/dev/null)" != '#!/usr/bin/env bash' ]; then
    bootstrap_installer="$(mktemp)"
    curl -fsSL https://www.privatenumber.in/edge/install-edge.sh -o "$bootstrap_installer"
    install -o root -g root -m 0755 "$bootstrap_installer" /usr/local/sbin/private-number-edge-update
    rm -f "$bootstrap_installer"
    exec /usr/bin/env PRIVATE_NUMBER_MANUAL_INSTALL=1 bash /usr/local/sbin/private-number-edge-update "$@"
fi
set -euo pipefail

reconnect=false
push_old_data=false
for argument in "$@"; do
    case "$argument" in
        --reconnect) reconnect=true ;;
        --push-old-data) push_old_data=true ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done
if [[ "$push_old_data" == true && "$reconnect" != true ]]; then
    echo "--push-old-data may only be used with --reconnect." >&2; exit 2
fi

api_url="${PRIVATE_NUMBER_API_URL:-https://app.privatenumber.in}"
node_id=""
node_location=""
reconnect_pending=false
if [[ -s /etc/private-number-edge/edge.env ]]; then
    node_id="$(sed -n 's/^Node__NodeId=//p' /etc/private-number-edge/edge.env)"
    node_location="$(sed -n 's/^Node__Location=//p' /etc/private-number-edge/edge.env)"
    api_url="${PRIVATE_NUMBER_API_URL:-$(sed -n 's/^Node__ApiBaseUrl=//p' /etc/private-number-edge/edge.env)}"
    if grep -q '^Node__ReconnectPending=true$' /etc/private-number-edge/edge.env; then reconnect_pending=true; fi
fi
case "$(uname -m)" in x86_64) runtime=linux-x64 ;; aarch64|arm64) runtime=linux-arm64 ;; *) echo "Unsupported architecture." >&2; exit 2 ;; esac

if ! command -v curl >/dev/null || ! command -v jq >/dev/null || ! command -v tar >/dev/null ||
    ! command -v openssl >/dev/null || ! command -v asterisk >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl jq tar openssl asterisk
fi
if command -v timedatectl >/dev/null; then
    timedatectl set-ntp true >/dev/null 2>&1 || echo "Warning: automatic time synchronization could not be enabled." >&2
fi
install -o root -g root -m 0755 /dev/stdin /usr/local/sbin/private-number-edge-time-sync <<'TIME_SYNC'
#!/usr/bin/env bash
set -u
timedatectl set-ntp true >/dev/null 2>&1 || true
systemctl try-restart systemd-timesyncd.service chrony.service chronyd.service 2>/dev/null || true
[[ "$(timedatectl show --property=NTP --value 2>/dev/null)" == "yes" ]]
TIME_SYNC
install -o root -g root -m 0440 /dev/stdin /etc/sudoers.d/private-number-edge-time-sync <<'SUDOERS'
private-number-edge ALL=(root) NOPASSWD: /usr/local/sbin/private-number-edge-time-sync
SUDOERS
inventory_hostname="$(hostname 2>/dev/null || true)"
inventory_os="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | tr -d '"' || true)"
inventory_kernel="$(uname -r 2>/dev/null || true)"
inventory_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || date +%Z)"
inventory_ntp_enabled="$(timedatectl show --property=NTP --value 2>/dev/null || true)"
inventory_ntp_synchronized="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
inventory_local_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
management_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n 1 || true)"
management_ip="${management_ip:-$inventory_local_ip}"
if [[ -z "$management_ip" ]]; then echo "Could not determine the edge LAN address." >&2; exit 2; fi
inventory_cpu="$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1 || true)"
inventory_processors="$(nproc 2>/dev/null || echo 0)"
inventory_memory="$(awk '/MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo 2>/dev/null || echo 0)"
inventory_disk="$(df -B1 / 2>/dev/null | awk 'NR == 2 {print $2}' || echo 0)"

enrollment_json() {
    jq -nc --arg runtime "$runtime" --arg hostname "$inventory_hostname" --arg operatingSystem "$inventory_os" \
        --arg kernelVersion "$inventory_kernel" --arg timeZone "$inventory_timezone" --arg localIpAddress "$inventory_local_ip" \
        --arg cpuModel "$inventory_cpu" --argjson processorCount "${inventory_processors:-0}" \
        --argjson memoryBytes "${inventory_memory:-0}" --argjson diskBytes "${inventory_disk:-0}" \
        --arg nodeReportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ntpEnabled "$inventory_ntp_enabled" \
        --arg ntpSynchronized "$inventory_ntp_synchronized" \
        '{runtime:$runtime,hostname:$hostname,operatingSystem:$operatingSystem,kernelVersion:$kernelVersion,timeZone:$timeZone,localIpAddress:$localIpAddress,cpuModel:$cpuModel,processorCount:$processorCount,memoryBytes:$memoryBytes,diskBytes:$diskBytes,nodeReportedAt:$nodeReportedAt,ntpEnabled:(if $ntpEnabled=="yes" then true elif $ntpEnabled=="no" then false else null end),ntpSynchronized:(if $ntpSynchronized=="yes" then true elif $ntpSynchronized=="no" then false else null end)}'
}

heartbeat_json() {
    jq -nc --arg nodeId "$node_id" --arg runtime "$runtime" --arg installedVersion "$1" --argjson healthy "$2" \
        --arg hostname "$inventory_hostname" --arg operatingSystem "$inventory_os" --arg kernelVersion "$inventory_kernel" \
        --arg timeZone "$inventory_timezone" --arg localIpAddress "$inventory_local_ip" --arg cpuModel "$inventory_cpu" \
        --argjson processorCount "${inventory_processors:-0}" --argjson memoryBytes "${inventory_memory:-0}" \
        --argjson diskBytes "${inventory_disk:-0}" --arg nodeReportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg ntpEnabled "$inventory_ntp_enabled" --arg ntpSynchronized "$inventory_ntp_synchronized" \
        '{nodeId:$nodeId,runtime:$runtime,installedVersion:(if $installedVersion == "" then null else $installedVersion end),healthy:$healthy,outboxDepth:0,hostname:$hostname,operatingSystem:$operatingSystem,kernelVersion:$kernelVersion,timeZone:$timeZone,localIpAddress:$localIpAddress,cpuModel:$cpuModel,processorCount:$processorCount,memoryBytes:$memoryBytes,diskBytes:$diskBytes,nodeReportedAt:$nodeReportedAt,ntpEnabled:(if $ntpEnabled=="yes" then true elif $ntpEnabled=="no" then false else null end),ntpSynchronized:(if $ntpSynchronized=="yes" then true elif $ntpSynchronized=="no" then false else null end)}'
}
id private-number-edge >/dev/null 2>&1 || useradd --system --home /var/lib/private-number-edge --create-home --shell /usr/sbin/nologin private-number-edge
getent group asterisk >/dev/null 2>&1 || { echo "The Asterisk package did not create its service group." >&2; exit 2; }
usermod -aG asterisk private-number-edge
install -d -o private-number-edge -g asterisk -m 0750 /var/lib/private-number-edge
install -d -o private-number-edge -g private-number-edge -m 0750 /var/lib/private-number-edge/data
install -d -o private-number-edge -g asterisk -m 2750 /var/lib/private-number-edge/asterisk
install -d -o root -g root -m 0755 /opt/private-number-edge/releases
install -d -o root -g private-number-edge -m 0750 /etc/private-number-edge
install -d -o root -g root -m 0700 /etc/private-number-edge/backups

runtime_configuration=""
if [[ -s /etc/private-number-edge/edge.env ]]; then
    device_code="$(sed -n 's/^Node__Credential=//p' /etc/private-number-edge/edge.env)"
    if [[ -z "$device_code" ]]; then echo "Existing edge configuration has no credential." >&2; exit 2; fi
    configuration_response="$(mktemp)"
    configuration_status="$(curl --silent --show-error -o "$configuration_response" -w '%{http_code}' \
        -H "Authorization: Bearer $device_code" "$api_url/api/v1/edge/runtime-configuration")"
    if [[ "$configuration_status" == 200 ]]; then
        if [[ "$reconnect" == true && "$reconnect_pending" != true ]]; then
            echo "This edge identity is still active; --reconnect is only for a revoked setup." >&2
            rm -f "$configuration_response"; exit 2
        fi
        runtime_configuration="$(cat "$configuration_response")"
        if [[ "$reconnect_pending" == true ]]; then
            echo "Continuing the pending edge reconnection."
        else echo "Using the existing enrolled node credential."
        fi
    elif [[ "$configuration_status" == 401 || "$configuration_status" == 403 ]]; then
        if [[ "$reconnect" != true ]]; then
            echo "The existing edge identity was revoked. Reconnect explicitly with:" >&2
            echo "curl -fsSL https://www.privatenumber.in/edge/install-edge.sh | sudo sh -s -- --reconnect" >&2
            echo "Add --push-old-data only when the archived operational history must be uploaded." >&2
            rm -f "$configuration_response"; exit 3
        fi
        revoked_backup="/etc/private-number-edge/backups/edge.env.revoked-$(date -u +%Y%m%dT%H%M%SZ)"
        reconnect_backup="/var/lib/private-number-edge/backups/reconnect-$(date -u +%Y%m%dT%H%M%SZ)"
        install -d -o root -g private-number-edge -m 0750 "$reconnect_backup"
        reconnect_database="$(sed -n 's/^Node__DatabasePath=//p' /etc/private-number-edge/edge.env)"
        reconnect_database="${reconnect_database:-/var/lib/private-number-edge/data/edge.db}"
        case "$reconnect_database" in /var/lib/private-number-edge/data/*) ;; *) echo "Refusing to back up an edge database outside the managed data directory." >&2; exit 2 ;; esac
        for database_file in "$reconnect_database" "$reconnect_database-wal" "$reconnect_database-shm"; do
            if [[ -f "$database_file" ]]; then cp -a "$database_file" "$reconnect_backup/"; fi
        done
        mv /etc/private-number-edge/edge.env "$revoked_backup"
        chown root:root "$revoked_backup"; chmod 0600 "$revoked_backup"
        device_code=""; node_id=""; node_location=""
        echo "The previous edge identity was revoked. Starting a fresh enrollment."
    else
        echo "Could not validate the existing edge identity: central API returned HTTP $configuration_status." >&2
        rm -f "$configuration_response"; exit 1
    fi
    rm -f "$configuration_response"
fi

if [[ -z "${device_code:-}" ]]; then
    enrollment="$(curl --fail --silent --show-error -H 'Content-Type: application/json' \
        -d "$(enrollment_json)" \
        "$api_url/api/v1/edge/enrollments")"
    device_code="$(jq -r .deviceCode <<<"$enrollment")"
    echo; echo "Approve this edge node in the PrivateNumber admin portal:"
    echo "$(jq -r .verificationUriComplete <<<"$enrollment")"
    echo "Device code: $(jq -r .userCode <<<"$enrollment")"; echo
    while true; do
        response_file="$(mktemp)"
        status="$(curl --silent --show-error -o "$response_file" -w '%{http_code}' -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg deviceCode "$device_code" '{deviceCode:$deviceCode}')" \
            "$api_url/api/v1/edge/enrollments/token")"
        if [[ "$status" == 200 ]]; then
            node_id="$(jq -r .nodeId "$response_file")"
            node_location="$(jq -r .location "$response_file")"
            rm -f "$response_file"
            break
        fi
        error="$(jq -r '.error // "unknown"' "$response_file")"; rm -f "$response_file"
        if [[ "$error" != authorization_pending ]]; then echo "Enrollment failed: $error" >&2; exit 1; fi
        sleep 5
    done
    umask 0027
    printf 'Node__NodeId=%s\nNode__Location=%s\nNode__ApiBaseUrl=%s\nNode__DatabasePath=/var/lib/private-number-edge/data/edge.db\nNode__Credential=%s\n' \
        "$node_id" "$node_location" "$api_url" "$device_code" > /etc/private-number-edge/edge.env
    if [[ "$reconnect" == true ]]; then
        reconnect_pending=true
        printf 'Node__ReconnectPending=true\n' >> /etc/private-number-edge/edge.env
        if [[ "$push_old_data" != true ]]; then
            printf 'Node__UploadSince=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /etc/private-number-edge/edge.env
        fi
    fi
    chown root:private-number-edge /etc/private-number-edge/edge.env
    chmod 0640 /etc/private-number-edge/edge.env
    rm -f /var/lib/private-number-edge/node-revoked
fi

if [[ -z "$runtime_configuration" ]]; then
    runtime_configuration="$(curl --fail --silent --show-error \
        -H "Authorization: Bearer $device_code" \
        "$api_url/api/v1/edge/runtime-configuration")"
fi
bugsnag_api_key="$(jq -r '.bugsnagApiKey // empty' <<<"$runtime_configuration")"
sed -i '/^Bugsnag__ApiKey=/d' /etc/private-number-edge/edge.env
if [[ -n "$bugsnag_api_key" ]]; then printf 'Bugsnag__ApiKey=%s\n' "$bugsnag_api_key" >> /etc/private-number-edge/edge.env; fi

ari_username="private-number-edge"
ari_password="$(sed -n 's/^Asterisk__Ari__Password=//p' /etc/private-number-edge/edge.env)"
if [[ -z "$ari_password" ]]; then ari_password="$(openssl rand -hex 32)"; fi
edge_environment_before="$(sha256sum /etc/private-number-edge/edge.env | cut -d' ' -f1)"
sed -i \
    -e '/^ASPNETCORE_URLS=/d' \
    -e '/^Asterisk__Ari__/d' \
    -e '/^Asterisk__GatewayManagement__ConfigurationPath=/d' \
    /etc/private-number-edge/edge.env
printf 'ASPNETCORE_URLS=http://%s:5100\nAsterisk__Ari__Enabled=true\nAsterisk__Ari__BaseUrl=http://127.0.0.1:8088/ari/\nAsterisk__Ari__Application=private-number\nAsterisk__Ari__ServerId=%s\nAsterisk__Ari__Username=%s\nAsterisk__Ari__Password=%s\nAsterisk__GatewayManagement__ConfigurationPath=/var/lib/private-number-edge/asterisk/private-number-gateways.conf\n' \
    "$management_ip" "$node_id" "$ari_username" "$ari_password" >> /etc/private-number-edge/edge.env
chown root:private-number-edge /etc/private-number-edge/edge.env
chmod 0640 /etc/private-number-edge/edge.env
edge_environment_after="$(sha256sum /etc/private-number-edge/edge.env | cut -d' ' -f1)"

ensure_asterisk_include() {
    local configuration="$1" include="$2"
    touch "$configuration"
    if ! grep -Fqx "$include" "$configuration"; then
        printf '\n%s\n' "$include" >> "$configuration"
        asterisk_needs_restart=true
    fi
}

install_asterisk_configuration() {
    local target="$1" candidate
    candidate="$(mktemp)"
    cat > "$candidate"
    if [[ ! -e "$target" ]] || ! cmp --silent "$candidate" "$target"; then
        install -o root -g asterisk -m 0640 "$candidate" "$target"
        asterisk_needs_restart=true
    fi
    rm -f "$candidate"
}

asterisk_needs_restart=false
if [[ ! -s /etc/asterisk/private-number-sip.key || ! -s /etc/asterisk/private-number-sip.crt ]]; then
    certificate_staging="$(mktemp -d)"
    certificate_name="${inventory_hostname:-$node_id}"
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
        -subj "/CN=$certificate_name" \
        -keyout "$certificate_staging/private-number-sip.key" \
        -out "$certificate_staging/private-number-sip.crt" >/dev/null 2>&1
    install -o root -g asterisk -m 0640 "$certificate_staging/private-number-sip.key" /etc/asterisk/private-number-sip.key
    install -o root -g asterisk -m 0640 "$certificate_staging/private-number-sip.crt" /etc/asterisk/private-number-sip.crt
    rm -rf "$certificate_staging"
    asterisk_needs_restart=true
fi
install_asterisk_configuration /etc/asterisk/private-number-http.conf <<'ASTERISK_HTTP'
[general](+)
enabled=yes
bindaddr=127.0.0.1
bindport=8088
ASTERISK_HTTP
install_asterisk_configuration /etc/asterisk/private-number-core.conf <<'ASTERISK_CORE'
[files]
astctlpermissions=0660
astctlowner=asterisk
astctlgroup=asterisk
astctl=asterisk.ctl
ASTERISK_CORE
install_asterisk_configuration /etc/asterisk/private-number-ari.conf <<ASTERISK_ARI
[general](+)
enabled=yes
pretty=no

[$ari_username]
type=user
read_only=no
password=$ari_password
ASTERISK_ARI
install_asterisk_configuration /etc/asterisk/private-number-pjsip.conf <<ASTERISK_PJSIP
[transport-udp]
type=transport
protocol=udp
bind=$management_ip:5060

[transport-tcp]
type=transport
protocol=tcp
bind=$management_ip:5060

[transport-tls]
type=transport
protocol=tls
bind=$management_ip:5061
method=tlsv1_2
cert_file=/etc/asterisk/private-number-sip.crt
priv_key_file=/etc/asterisk/private-number-sip.key

#include /var/lib/private-number-edge/asterisk/private-number-gateways.conf
ASTERISK_PJSIP
install_asterisk_configuration /etc/asterisk/private-number-extensions.conf <<'ASTERISK_EXTENSIONS'
[private-number-inbound]
exten => _X!,1,NoOp(PrivateNumber inbound call to ${EXTEN})
 same => n,Set(__PN_CALLED_NUMBER=${EXTEN})
 same => n,Stasis(private-number,inbound,${EXTEN})
 same => n,Hangup()
ASTERISK_EXTENSIONS
if [[ ! -e /var/lib/private-number-edge/asterisk/private-number-gateways.conf ]]; then
    install -o private-number-edge -g asterisk -m 0660 /dev/stdin /var/lib/private-number-edge/asterisk/private-number-gateways.conf <<'ASTERISK_GATEWAYS'
; Generated by PrivateNumber Edge. Manual changes will be replaced.
ASTERISK_GATEWAYS
fi
ensure_asterisk_include /etc/asterisk/http.conf '#include private-number-http.conf'
ensure_asterisk_include /etc/asterisk/ari.conf '#include private-number-ari.conf'
ensure_asterisk_include /etc/asterisk/pjsip.conf '#include private-number-pjsip.conf'
ensure_asterisk_include /etc/asterisk/extensions.conf '#include private-number-extensions.conf'
ensure_asterisk_include /etc/asterisk/asterisk.conf '#include private-number-core.conf'
systemctl enable asterisk >/dev/null
if [[ "$asterisk_needs_restart" == true ]] || ! systemctl is-active --quiet asterisk; then
    systemctl restart asterisk
fi
if ! asterisk -rx 'core show version' >/dev/null 2>&1; then
    echo "Asterisk did not become ready after automatic configuration." >&2
    systemctl status asterisk --no-pager >&2 || true
    journalctl -u asterisk --no-pager -n 100 >&2 || true
    exit 1
fi
if ! curl --config - >/dev/null <<ARI_CHECK
url = "http://127.0.0.1:8088/ari/asterisk/info"
user = "$ari_username:$ari_password"
fail
silent
show-error
ARI_CHECK
then
    echo "Asterisk ARI did not accept the automatically generated edge credential." >&2
    exit 1
fi
if ! asterisk -rx 'pjsip show transport transport-udp' | grep -Fq "$management_ip:5060"; then
    echo "Asterisk did not load the managed SIP transport." >&2
    exit 1
fi
if ! asterisk -rx 'pjsip show transport transport-tcp' | grep -Fq "$management_ip:5060" ||
    ! asterisk -rx 'pjsip show transport transport-tls' | grep -Fq "$management_ip:5061"; then
    echo "Asterisk did not load every managed SIP transport." >&2
    exit 1
fi
if ! asterisk -rx 'dialplan show private-number-inbound' | grep -Fq 'Stasis(private-number'; then
    echo "Asterisk did not load the managed inbound call flow." >&2
    exit 1
fi
if ! runuser -u private-number-edge -- asterisk -rx 'core show version' >/dev/null 2>&1; then
    echo "The edge service account cannot access the local Asterisk control socket." >&2
    exit 1
fi
if [[ "$asterisk_needs_restart" == true || "$edge_environment_before" != "$edge_environment_after" ]] &&
    systemctl is-active --quiet private-number-edge 2>/dev/null; then
    systemctl restart private-number-edge
fi

if [[ "$0" != /usr/local/sbin/private-number-edge-update ]] || ! cmp --silent "$0" /usr/local/sbin/private-number-edge-update 2>/dev/null; then
    install -o root -g root -m 0755 "$0" /usr/local/sbin/private-number-edge-update
fi
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge-update.service <<'UNIT'
[Unit]
Description=Check for an authorized PrivateNumber Edge release
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/private-number-edge-update
UNIT
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge-update.timer <<'UNIT'
[Unit]
Description=PrivateNumber Edge release polling
[Timer]
OnActiveSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
UNIT
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge-update.path <<'UNIT'
[Unit]
Description=React to an authorized PrivateNumber Edge release
[Path]
PathExists=/var/lib/private-number-edge/update-requested
Unit=private-number-edge-update.service
[Install]
WantedBy=multi-user.target
UNIT
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge-decommission.service <<'UNIT'
[Unit]
Description=Stop all operations for a revoked PrivateNumber Edge node
[Service]
Type=oneshot
ExecStart=/bin/systemctl stop asterisk.service private-number-edge.service
UNIT
install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge-decommission.path <<'UNIT'
[Unit]
Description=React to PrivateNumber Edge node revocation
[Path]
PathExists=/var/lib/private-number-edge/node-revoked
Unit=private-number-edge-decommission.service
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now private-number-edge-update.path
systemctl enable --now private-number-edge-decommission.path

installed_version=""
current_release=""
development_build=false
if [[ -L /opt/private-number-edge/current ]]; then
    resolved_release="$(readlink -f /opt/private-number-edge/current 2>/dev/null || true)"
    case "$resolved_release" in
        /opt/private-number-edge/releases/*)
            if [[ -x "$resolved_release/PrivateNumber.Asterisk" ]]; then
                current_release="$resolved_release"
                installed_version="$(basename "$resolved_release")"
            fi
            ;;
    esac
fi
if [[ -f /opt/private-number-edge/current/.development-build &&
      "${PRIVATE_NUMBER_MANUAL_INSTALL:-0}" != 1 ]]; then
    development_build=true
    installed_version="Debug"
fi
initial_install=false
if [[ "$reconnect_pending" == true ]]; then installed_version=""; fi
if [[ -z "$installed_version" ]]; then initial_install=true; fi
healthy=false
if [[ -n "$installed_version" ]] && curl --fail --silent "http://$management_ip:5100/health" >/dev/null 2>&1; then healthy=true; fi
update_response="$(mktemp)"
update_status="$(curl --silent --show-error -o "$update_response" -w '%{http_code}' -H "Authorization: Bearer $device_code" -H 'Content-Type: application/json' \
    -d "$(heartbeat_json "$installed_version" "$healthy")" "$api_url/api/v1/edge/update")"
if [[ "$update_status" != 200 ]]; then
    echo "Initial edge release check failed: central API returned HTTP $update_status." >&2
    if [[ -s "$update_response" ]]; then sed -n '1,20p' "$update_response" >&2; fi
    systemctl status private-number-edge --no-pager 2>/dev/null || true
    journalctl -u private-number-edge --no-pager -n 50 2>/dev/null || true
    if [[ "$initial_install" == true ]]; then systemctl disable --now private-number-edge-update.timer >/dev/null 2>&1 || true; fi
    rm -f "$update_response"
    exit 1
fi
update="$(cat "$update_response")"; rm -f "$update_response"
rm -f /var/lib/private-number-edge/update-requested
if [[ "$development_build" == true ]]; then
    echo "Debug build is active; its status was reported and automatic edge updates are paused."
    exit 0
fi
if [[ "$(jq -r .updateAvailable <<<"$update")" != true ]]; then
    if [[ "$initial_install" == true ]]; then
        systemctl disable --now private-number-edge-update.timer >/dev/null 2>&1 || true
        echo "Node enrolled, but no initial edge release is currently authorized. The update timer was not enabled." >&2
        exit 1
    fi
    echo "No newer edge release is currently authorized."; exit 0
fi

version="$(jq -r .version <<<"$update")"; digest="$(jq -r .sha256 <<<"$update")"; expected_size="$(jq -r .sizeBytes <<<"$update")"; download_url="$(jq -r .downloadUrl <<<"$update")"
archive="$(mktemp)"; staging="$(mktemp -d)"; trap 'rm -f "$archive"; rm -rf "$staging"' EXIT
curl --fail --silent --show-error -H "Authorization: Bearer $device_code" -o "$archive" "$api_url$download_url"
actual_size="$(stat -c '%s' "$archive")"
if [[ "$actual_size" != "$expected_size" ]]; then echo "Downloaded package size did not match the approved release." >&2; exit 1; fi
printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status
tar -xzf "$archive" -C "$staging"
release_dir="/opt/private-number-edge/releases/$version"
install -d -m 0755 "$release_dir"; cp -a "$staging"/. "$release_dir"/; chmod 0755 "$release_dir/PrivateNumber.Asterisk"
previous_release="$current_release"

database_path="$(sed -n 's/^Node__DatabasePath=//p' /etc/private-number-edge/edge.env)"
database_path="${database_path:-/var/lib/private-number-edge/data/edge.db}"
case "$database_path" in
    /var/lib/private-number-edge/data/*) ;;
    *) echo "Refusing to back up an edge database outside /var/lib/private-number-edge/data." >&2; exit 1 ;;
esac
database_name="$(basename "$database_path")"
backup_root="/var/lib/private-number-edge/backups"
backup_dir="$backup_root/pre-$version-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -o root -g private-number-edge -m 0750 "$backup_root" "$backup_dir"
systemctl stop private-number-edge >/dev/null 2>&1 || true
for database_file in "$database_path" "$database_path-wal" "$database_path-shm"; do
    if [[ -f "$database_file" ]]; then cp -a "$database_file" "$backup_dir/"; fi
done
ln -sfn "$release_dir" /opt/private-number-edge/current

install -o root -g root -m 0644 /dev/stdin /etc/systemd/system/private-number-edge.service <<'UNIT'
[Unit]
Description=PrivateNumber Telephony Edge
After=network-online.target asterisk.service
Wants=network-online.target asterisk.service
[Service]
User=private-number-edge
Group=private-number-edge
SupplementaryGroups=asterisk
WorkingDirectory=/opt/private-number-edge/current
ExecStart=/opt/private-number-edge/current/PrivateNumber.Asterisk
Environment=ASPNETCORE_ENVIRONMENT=Production
EnvironmentFile=/etc/private-number-edge/edge.env
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/private-number-edge
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable private-number-edge
systemctl restart private-number-edge
for attempt in $(seq 1 20); do
    if curl --fail --silent "http://$management_ip:5100/health" >/dev/null; then
        curl --fail --silent --show-error -H "Authorization: Bearer $device_code" -H 'Content-Type: application/json' \
            -d "$(heartbeat_json "$version" true)" \
            "$api_url/api/v1/edge/update" >/dev/null
        sed -i '/^Node__ReconnectPending=/d' /etc/private-number-edge/edge.env
        systemctl enable --now private-number-edge-update.timer
        find "$backup_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | tail -n +11 | cut -d' ' -f2- | while IFS= read -r expired_backup; do
            case "$expired_backup" in "$backup_root"/*) rm -rf -- "$expired_backup" ;; esac
        done
        echo "PrivateNumber Edge $version installed and healthy."
        exit 0
    fi
    sleep 2
done
systemctl stop private-number-edge >/dev/null 2>&1 || true
rm -f -- "$database_path" "$database_path-wal" "$database_path-shm"
for database_file in "$backup_dir/$database_name" "$backup_dir/$database_name-wal" "$backup_dir/$database_name-shm"; do
    if [[ -f "$database_file" ]]; then cp -a "$database_file" "$(dirname "$database_path")/"; fi
done
if [[ -n "$previous_release" && "$previous_release" != "$release_dir" && -d "$previous_release" ]]; then
    ln -sfn "$previous_release" /opt/private-number-edge/current
    systemctl restart private-number-edge
    echo "The new release failed its health check; restored $previous_release." >&2
else
    rm -f /opt/private-number-edge/current
    systemctl stop private-number-edge >/dev/null 2>&1 || true
    previous_release=""
    echo "The initial release failed its health check; no prior release was available to restore." >&2
fi
reported_version="$version"
if [[ -n "$previous_release" ]]; then reported_version="$(basename "$previous_release")"; fi
curl --silent --show-error -H "Authorization: Bearer $device_code" -H 'Content-Type: application/json' \
    -d "$(heartbeat_json "$reported_version" false)" \
    "$api_url/api/v1/edge/update" >/dev/null || true
if [[ "$initial_install" == true ]]; then systemctl disable --now private-number-edge-update.timer >/dev/null 2>&1 || true; fi
journalctl -u private-number-edge --no-pager -n 100; exit 1
