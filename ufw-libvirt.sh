#!/usr/bin/env bash
#
# ufw-libvirt - let libvirt guests reach DNS, DHCP and the internet on a host
#               where ufw's default INPUT and FORWARD policies are DROP.
#
# Usage:  sudo ./ufw-libvirt.sh                      # apply
#         ./ufw-libvirt.sh --dry-run                 # show what it would run
#         sudo ./ufw-libvirt.sh --status             # show current state
#         sudo ./ufw-libvirt.sh --remove             # undo
#
# See README.md for why each rule is needed.

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION - edit these if your libvirt network is not the stock one.
#
# Override per run, either way:
#     sudo LIBVIRT_SUBNET=10.10.0.0/24 ./ufw-libvirt.sh
#     sudo ./ufw-libvirt.sh --subnet 10.10.0.0/24 --bridge virbr1
# ---------------------------------------------------------------------------
LIBVIRT_SUBNET="${LIBVIRT_SUBNET:-192.168.122.0/24}"
LIBVIRT_BRIDGE="${LIBVIRT_BRIDGE:-virbr0}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"   # only used for the sanity check
# ---------------------------------------------------------------------------

MODE=apply

msg()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*" >&2; }
die()  { printf 'ufw-libvirt: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --subnet CIDR    guest network, default 192.168.122.0/24
  --bridge IFACE   libvirt bridge, default virbr0
  --network NAME   libvirt network to cross-check against, default "default"
  --dry-run        print the ufw commands without running them
  --status         show whether the rules are loaded, and recent blocks
  --remove         delete the rules this script adds
  -h, --help       this text
EOF
}

# --- argument parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)  [[ $# -ge 2 ]] || die "--subnet needs a value";  LIBVIRT_SUBNET="$2";  shift 2 ;;
        --bridge)  [[ $# -ge 2 ]] || die "--bridge needs a value";  LIBVIRT_BRIDGE="$2";  shift 2 ;;
        --network) [[ $# -ge 2 ]] || die "--network needs a value"; LIBVIRT_NETWORK="$2"; shift 2 ;;
        --subnet=*)  LIBVIRT_SUBNET="${1#*=}";  shift ;;
        --bridge=*)  LIBVIRT_BRIDGE="${1#*=}";  shift ;;
        --network=*) LIBVIRT_NETWORK="${1#*=}"; shift ;;
        --dry-run) MODE=dry-run; shift ;;
        --status)  MODE=status;  shift ;;
        --remove)  MODE=remove;  shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

# --- validation ------------------------------------------------------------
valid_cidr() {
    local cidr=$1 ip prefix o
    [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    ip=${cidr%/*}; prefix=${cidr#*/}
    (( prefix >= 0 && prefix <= 32 )) || return 1
    local IFS=.
    for o in $ip; do (( o >= 0 && o <= 255 )) || return 1; done
    return 0
}

valid_cidr "$LIBVIRT_SUBNET" || die "'$LIBVIRT_SUBNET' is not a valid IPv4 CIDR (expected e.g. 192.168.122.0/24)"
[[ $LIBVIRT_BRIDGE =~ ^[A-Za-z0-9_.-]+$ ]] || die "'$LIBVIRT_BRIDGE' is not a valid interface name"

command -v ufw >/dev/null || die "ufw is not installed"

# --- re-exec as root when needed -------------------------------------------
# sudo's env_reset would drop LIBVIRT_* from the environment, so the values are
# passed back in as explicit flags instead.
if [[ $MODE != dry-run && $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "need root (run as root or install sudo)"
    args=(--subnet "$LIBVIRT_SUBNET" --bridge "$LIBVIRT_BRIDGE" --network "$LIBVIRT_NETWORK")
    [[ $MODE == apply ]] || args+=("--$MODE")
    msg "Re-running with sudo..."
    exec sudo -- "$0" "${args[@]}"
fi

# --- the rules -------------------------------------------------------------
# A "route " prefix marks a forward-chain rule (ufw route ...).
#
# Note on DHCP: a guest's initial DHCPDISCOVER is sent from 0.0.0.0 to
# 255.255.255.255 before it has an address, so that rule must NOT be scoped
# "from $LIBVIRT_SUBNET" - it would never match and DHCP would stay broken.
SPECS=(
    "allow in on $LIBVIRT_BRIDGE from $LIBVIRT_SUBNET to any port 53 proto udp"
    "allow in on $LIBVIRT_BRIDGE from $LIBVIRT_SUBNET to any port 53 proto tcp"
    "allow in on $LIBVIRT_BRIDGE to any port 67 proto udp"
    "route allow in on $LIBVIRT_BRIDGE from $LIBVIRT_SUBNET"
)

add_cmd() {  # spec -> command words on stdout, one per line
    local spec=$1
    if [[ $spec == "route "* ]]; then printf 'ufw route %s\n' "${spec#route }"
    else                              printf 'ufw %s\n' "$spec"; fi
}

del_cmd() {
    local spec=$1
    if [[ $spec == "route "* ]]; then printf 'ufw route delete %s\n' "${spec#route }"
    else                              printf 'ufw delete %s\n' "$spec"; fi
}

run_spec() {  # "$1" = full command line as a string
    local -a words
    read -r -a words <<<"$1"
    "${words[@]}"
}

# --- sanity check against what libvirt actually has ------------------------
mask2prefix() {
    local p=0 o a b c d
    IFS=. read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        while (( o )); do (( p += o & 1 )); (( o >>= 1 )); done
    done
    printf '%s\n' "$p"
}

cross_check() {
    command -v virsh >/dev/null || return 0
    local xml bridge addr netmask prefix i1 i2 i3 i4 m1 m2 m3 m4 detected
    xml=$(virsh -c qemu:///system net-dumpxml "$LIBVIRT_NETWORK" 2>/dev/null) || return 0
    [[ -n $xml ]] || return 0

    bridge=$(sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" <<<"$xml" | head -1)
    addr=$(sed -n "s/.*<ip address='\([^']*\)'.*/\1/p" <<<"$xml" | head -1)
    netmask=$(sed -n "s/.*netmask='\([^']*\)'.*/\1/p" <<<"$xml" | head -1)
    prefix=$(sed -n "s/.*<ip[^>]*prefix='\([^']*\)'.*/\1/p" <<<"$xml" | head -1)

    [[ -n $bridge && $bridge != "$LIBVIRT_BRIDGE" ]] &&
        warn "libvirt network '$LIBVIRT_NETWORK' uses bridge '$bridge', but --bridge is '$LIBVIRT_BRIDGE'"

    if [[ -n $addr ]]; then
        if [[ -z $prefix && -n $netmask ]]; then prefix=$(mask2prefix "$netmask"); fi
        if [[ -n $prefix ]]; then
            IFS=. read -r i1 i2 i3 i4 <<<"$addr"
            if [[ -n $netmask ]]; then IFS=. read -r m1 m2 m3 m4 <<<"$netmask"
            else m1=255 m2=255 m3=255 m4=0; fi
            detected=$(printf '%d.%d.%d.%d/%s' $((i1 & m1)) $((i2 & m2)) $((i3 & m3)) $((i4 & m4)) "$prefix")
            [[ $detected != "$LIBVIRT_SUBNET" ]] &&
                warn "libvirt network '$LIBVIRT_NETWORK' is $detected, but --subnet is $LIBVIRT_SUBNET"
        fi
    fi
    return 0
}

docker_check() {
    command -v docker >/dev/null || return 0
    systemctl is-active --quiet docker 2>/dev/null || return 0
    if command -v iptables >/dev/null &&
       ! iptables -S DOCKER-USER 2>/dev/null | grep -q 'ufw-user-forward'; then
        warn "Docker is running and its DOCKER-USER chain does not jump to ufw-user-forward."
        warn "Docker's own FORWARD drop can block guest traffic regardless of these rules."
        warn "See the 'Docker' section of README.md."
    fi
    return 0
}

ufw_active() { ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; }

# --- modes -----------------------------------------------------------------
case $MODE in
dry-run)
    cross_check
    msg "Would apply, for bridge $LIBVIRT_BRIDGE / subnet $LIBVIRT_SUBNET:"
    for s in "${SPECS[@]}"; do msg "    $(add_cmd "$s")"; done
    msg
    msg "Undo would be:"
    for s in "${SPECS[@]}"; do msg "    $(del_cmd "$s")"; done
    ;;

apply)
    cross_check
    msg "Applying ufw rules for $LIBVIRT_BRIDGE ($LIBVIRT_SUBNET):"
    for s in "${SPECS[@]}"; do
        cmd=$(add_cmd "$s")
        if out=$(run_spec "$cmd" 2>&1); then
            case "$out" in
                *"Skipping adding existing rule"*) ok "already present: $cmd" ;;
                *) ok "$cmd" ;;
            esac
        else
            printf '%s\n' "$out" >&2
            die "failed: $cmd"
        fi
    done
    docker_check
    msg
    if ufw_active; then
        msg "Rules are live. Verify from a guest with:  getent hosts example.com"
        msg "And watch for new drops with:  journalctl -k -f | grep 'UFW BLOCK.*$LIBVIRT_BRIDGE'"
    else
        warn "ufw is INACTIVE, so nothing is being filtered or allowed right now."
        warn "The rules are saved and will take effect when you run: ufw enable"
        warn "(This script never enables ufw itself - on a remote host that can cut off SSH.)"
    fi
    msg
    msg "These rules persist across reboots on their own: 'ufw allow' writes them to"
    msg "/etc/ufw/user.rules, and ufw.service reloads that file at every boot."
    msg "No extra systemd unit is needed. Check with: systemctl is-enabled ufw"
    ;;

remove)
    msg "Removing ufw rules for $LIBVIRT_BRIDGE ($LIBVIRT_SUBNET):"
    for s in "${SPECS[@]}"; do
        cmd=$(del_cmd "$s")
        if out=$(run_spec "$cmd" 2>&1); then ok "$cmd"
        else warn "not removed (probably absent): $cmd"; fi
    done
    msg
    msg "Guest DNS/DHCP/egress will break again unless something else allows it."
    ;;

status)
    msg "Configured:  bridge=$LIBVIRT_BRIDGE  subnet=$LIBVIRT_SUBNET  network=$LIBVIRT_NETWORK"
    cross_check
    msg
    msg "ufw:"
    ufw status verbose 2>/dev/null | sed -n '1,4p' | sed 's/^/    /'
    msg
    msg "Rules mentioning $LIBVIRT_BRIDGE:"
    if ufw status 2>/dev/null | grep -- "$LIBVIRT_BRIDGE" | sed 's/^/    /'; then :
    else msg "    (none - the fix is not applied)"; fi
    msg
    msg "Boot persistence:  ufw.service is $(systemctl is-enabled ufw 2>/dev/null || echo unknown)"
    msg
    if command -v journalctl >/dev/null; then
        n=$(journalctl -k -b 2>/dev/null | grep -c "UFW BLOCK.*$LIBVIRT_BRIDGE" || true)
        msg "[UFW BLOCK] entries on $LIBVIRT_BRIDGE this boot: ${n:-0}"
        [[ ${n:-0} -gt 0 ]] && msg "(entries from before the fix was applied are expected; check their timestamps)"
    fi
    ;;
esac
