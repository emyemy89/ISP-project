#!/usr/bin/env bash
# Focused black-box tests for the three routing grading categories:
#   same_path, IGP_disruption, BGP_transit
#
# Run inside the IK2215 lab VM, from the project directory:
#   bash test_routing_score.sh
#   bash test_routing_score.sh same_path
#   bash test_routing_score.sh igp_disruption
#   bash test_routing_score.sh bgp_transit
#
# The script changes link state during disruption tests. Every changed link is
# restored on normal exit and on INT/TERM/HUP. Do not run two copies at once.

set -u
set -o pipefail

PASS=0
FAIL=0
SKIP=0
CHANGED_LINKS=()

green='\033[0;32m'; red='\033[0;31m'; yellow='\033[1;33m'; reset='\033[0m'

pass() { printf "  ${green}PASS${reset} %-24s %s\n" "$1" "$2"; PASS=$((PASS+1)); }
fail() { printf "  ${red}FAIL${reset} %-24s %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf "  ${yellow}SKIP${reset} %-24s %s\n" "$1" "$2"; SKIP=$((SKIP+1)); }
section() { printf '\n==== %s ====\n' "$1"; }


kexec() {
    local node="$1"; shift
    kathara exec "$node" -- "$@" 2>/dev/null
}

vty() {
    local node="$1"; shift
    kexec "$node" vtysh --command "$*"
}

link_down() {
    local node="$1" iface="$2"
    if kexec "$node" ip link set dev "$iface" down; then
        CHANGED_LINKS+=("$node:$iface")
        return 0
    fi
    return 1
}

link_up() {
    local node="$1" iface="$2"
    kexec "$node" ip link set dev "$iface" up >/dev/null 2>&1 || true
    local kept=() item
    for item in "${CHANGED_LINKS[@]}"; do
        [ "$item" = "$node:$iface" ] || kept+=("$item")
    done
    CHANGED_LINKS=("${kept[@]}")
}

cleanup() {
    local item node iface
    for item in "${CHANGED_LINKS[@]}"; do
        node=${item%%:*}; iface=${item#*:}
        kexec "$node" ip link set dev "$iface" up >/dev/null 2>&1 || true
    done
    CHANGED_LINKS=()
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

wait_ping() {
    local node="$1" dst="$2" limit="${3:-60}" i
    for ((i=0; i<limit; i++)); do
        if kexec "$node" ping -n -w 1 -W 1 "$dst" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_no_ping() {
    local node="$1" dst="$2" limit="${3:-60}" i
    for ((i=0; i<limit; i++)); do
        if ! kexec "$node" ping -n -w 1 -W 1 "$dst" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ospf_full_total() {
    local total=0 node n
    for node in as102r1 as102r2 as102r3 as102r4; do
        n=$(vty "$node" show ip ospf neighbor | grep -c 'Full' || true)
        total=$((total+n))
    done
    printf '%s\n' "$total"
}

wait_ospf_total() {
    local expected="$1" limit="${2:-60}" i current stable=0
    for ((i=0; i<limit; i++)); do
        current=$(ospf_full_total)
        if [ "$current" = "$expected" ]; then
            stable=$((stable+1))
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
        fi
        sleep 1
    done
    return 1
}

client_ip() {
    kexec "$1" ip -4 -o addr show dev eth0 |
        awk '$3=="inet" {split($4,a,"/"); print a[1]; exit}'
}

# Convert every responding internal hop into an R1/R2/R3/R4 sequence.
# Consecutive duplicates are removed. This deliberately compares router paths,
# not interface-address strings.
trace_router_hops() {
    local node="$1" dst="$2"
    kexec "$node" traceroute -n --wait=2 --queries=1 --max-hops=16 "$dst" |
    awk '
      $1 ~ /^[0-9]+$/ {
        ip=$2; r=""
        if (ip ~ /^(1\.0\.0\.5|1\.102\.3\.(0|2|5)|1\.102\.4\.1)$/) r="R1"
        else if (ip ~ /^(2\.21\.0\.1|1\.102\.3\.(1|6)|1\.102\.4\.2)$/) r="R2"
        else if (ip ~ /^(1\.102\.1\.1|1\.102\.3\.(3|7|8)|1\.102\.4\.3)$/) r="R3"
        else if (ip ~ /^(1\.102\.2\.1|1\.102\.3\.(4|9)|1\.102\.4\.4)$/) r="R4"
        if (r != "" && r != last) { out=(out=="" ? r : out "-" r); last=r }
      }
      END { print out }'
}

# Add the logical ingress/egress router, because a host destination does not
# itself map to a router and a router-originated trace does not show its source.
logical_path() {
    local node="$1" dst="$2" first="$3" last="$4" hops
    hops=$(trace_router_hops "$node" "$dst")
    [ -z "$hops" ] && hops="$first"
    case "-$hops-" in *"-$first-"*) ;; *) hops="$first-$hops";; esac
    case "-$hops-" in *"-$last-"*) ;; *) hops="$hops-$last";; esac
    printf '%s\n' "$hops"
}

assert_path() {
    local id="$1" node="$2" dst="$3" first="$4" last="$5" expected="$6" actual
    actual=$(logical_path "$node" "$dst" "$first" "$last")
    if [ "$actual" = "$expected" ]; then
        pass "$id" "$actual"
    else
        fail "$id" "expected $expected, got ${actual:-<empty>}"
    fi
}

test_same_path() {
    section 'same_path: complete forward/reverse router paths'
    local cip
    cip=$(client_ip as102c1)
    if [[ ! "$cip" =~ ^1\.102\.2\.[0-9]+$ ]]; then
        fail 'SP.preflight' "as102c1 has no DHCP address (got '$cip')"
        return
    fi

    # These are the deterministic primary paths implied by the configured
    # costs. Each direction is asserted independently, not merely searched for
    # one expected hop.
    assert_path SP1.forward as102r1 "$cip"       R1 R4 R1-R4
    assert_path SP1.reverse as102c1 1.102.4.1    R4 R1 R4-R1
    assert_path SP2.forward as102r1 1.102.1.2    R1 R3 R1-R3
    assert_path SP2.reverse as102s1 1.102.4.1    R3 R1 R3-R1
    assert_path SP3.forward as102r2 "$cip"       R2 R4 R2-R1-R4
    assert_path SP3.reverse as102c1 1.102.4.2    R4 R2 R4-R1-R2
    assert_path SP4.forward as102r2 1.102.1.2    R2 R3 R2-R3
    assert_path SP4.reverse as102s1 1.102.4.2    R3 R2 R3-R2
    assert_path SP5.forward as102c1 1.102.1.2    R4 R3 R4-R3
    assert_path SP5.reverse as102s1 "$cip"       R3 R4 R3-R4
}

no_ecmp_route() {
    local node="$1" prefix="$2" text nh
    text=$(vty "$node" show ip route "$prefix")
    [ -n "$text" ] || return 1
    # FRR 9 prints active next hops as "* ADDRESS, via IFACE".
    # Connected routes are not passed to this function.
    nh=$(printf '%s\n' "$text" | grep -cE '^[[:space:]]+(\*[[:space:]]+)?[0-9]+(\.[0-9]+){3},[[:space:]]+via[[:space:]]+' || true)
    [ "$nh" -eq 1 ]
}

igp_matrix() {
    local cip="$1" bad=0 node dst
    for node in as102r1 as102r2 as102r3 as102r4; do
        for dst in 1.102.1.2 "$cip"; do
            kexec "$node" ping -n -w 2 -W 2 "$dst" >/dev/null 2>&1 || bad=1
        done
    done
    kexec as102s1 ping -n -w 2 -W 2 "$cip" >/dev/null 2>&1 || bad=1
    kexec as102c1 ping -n -w 2 -W 2 1.102.1.2 >/dev/null 2>&1 || bad=1
    kexec as102c1 ping -n -w 2 -W 2 1.0.1.2 >/dev/null 2>&1 || bad=1
    kexec as102c1 ping -n -w 2 -W 2 2.21.1.1 >/dev/null 2>&1 || bad=1

    no_ecmp_route as102r1 1.102.1.0/24 || bad=1
    no_ecmp_route as102r1 1.102.2.0/24 || bad=1
    no_ecmp_route as102r2 1.102.1.0/24 || bad=1
    no_ecmp_route as102r2 1.102.2.0/24 || bad=1
    no_ecmp_route as102r3 1.102.2.0/24 || bad=1
    no_ecmp_route as102r4 1.102.1.0/24 || bad=1
    return "$bad"
}

test_igp_disruption() {
    section 'IGP_disruption: every internal point-to-point link'
    local cip baseline item name node iface down_total
    cip=$(client_ip as102c1)
    if [[ ! "$cip" =~ ^1\.102\.2\.[0-9]+$ ]]; then
        fail 'IGP.preflight' "as102c1 has no DHCP address (got '$cip')"
        return
    fi
    baseline=$(ospf_full_total)
    if [ "$baseline" -ne 10 ]; then
        fail 'IGP.preflight' "expected 10 Full adjacency entries, got $baseline"
        return
    fi
    down_total=$((baseline-2))

    # One side is administratively disabled; that is sufficient to remove the
    # bidirectional link and matches a physical link failure.
    for item in \
        L12:as102r1:eth1 \
        L13:as102r1:eth2 \
        L14:as102r1:eth3 \
        L23:as102r2:eth2 \
        L34:as102r3:eth3
    do
        IFS=: read -r name node iface <<<"$item"
        if ! link_down "$node" "$iface"; then
            fail "IGP.$name" "could not disable $node/$iface"
            continue
        fi
        if ! wait_ospf_total "$down_total" 60; then
            fail "IGP.$name" "OSPF did not converge to $down_total Full entries"
        elif igp_matrix "$cip"; then
            pass "IGP.$name" 'all endpoint classes reachable; no ECMP detected'
        else
            fail "IGP.$name" 'connectivity matrix or single-next-hop check failed'
        fi
        link_up "$node" "$iface"
        if ! wait_ospf_total "$baseline" 60; then
            fail "IGP.$name.restore" "OSPF did not return to $baseline Full entries"
            return
        fi
    done
}

trace_contains() {
    local node="$1" dst="$2" pattern="$3"
    kexec "$node" traceroute -n --wait=2 --queries=1 --max-hops=20 "$dst" | grep -qE "$pattern"
}

trace_excludes() {
    local node="$1" dst="$2" pattern="$3"
    ! kexec "$node" traceroute -n --wait=2 --queries=1 --max-hops=20 "$dst" | grep -qE "$pattern"
}

test_bgp_transit() {
    section 'BGP_transit: normal policy and both primary-uplink failures'
    local cip
    cip=$(client_ip as102c1)
    if [[ ! "$cip" =~ ^1\.102\.2\.[0-9]+$ ]]; then
        fail 'BGP.preflight' "as102c1 has no DHCP address (got '$cip')"
        return
    fi

    # Normal operation: AS102 uses AS1 for the Internet, direct peering for
    # AS21, and AS21 must not use AS102 to reach the Internet.
    if trace_contains as102c1 1.0.1.2 '1\.102\.3\.5|1\.0\.0\.4' &&
       trace_contains as102c1 2.21.1.1 '1\.102\.3\.1|2\.21\.0\.0' &&
       trace_excludes as21h1 1.0.1.2 '1\.102\.|2\.21\.0\.1'; then
        pass BGP.normal 'primary AS1 path, direct AS21 path, no normal transit'
    else
        fail BGP.normal 'one or more normal data-plane policies are wrong'
    fi

    # AS102 primary provider failure: AS102 must retain general Internet access
    # through AS21, while the direct AS21 connection remains usable.
    if ! link_down as102r1 eth0; then
        fail BGP.as102_primary_down 'could not disable as102r1/eth0'
    else
        if wait_ping as102c1 1.0.1.2 90 &&
           trace_contains as102c1 1.0.1.2 '1\.102\.3\.1|2\.21\.0\.0'; then
            pass BGP.as102_primary_down 'AS102 Internet traffic failed over via AS21'
        else
            fail BGP.as102_primary_down 'AS102 did not obtain working backup Internet service'
        fi
        link_up as102r1 eth0
        if ! wait_ping as102c1 1.0.1.2 90; then
            fail BGP.as102_restore 'Internet access did not recover after restoring r1/eth0'
            return
        fi
    fi

    # AS21 primary provider failure: AS102 is allowed to provide emergency
    # transit for AS21. Check both reachability and that the data plane really
    # enters AS102 over the private peering.
    if ! link_down as21r1 eth1; then
        fail BGP.as21_primary_down 'could not disable as21r1/eth1'
    else
        if wait_ping as21h1 1.0.1.2 120 &&
           trace_contains as21h1 1.0.1.2 '2\.21\.0\.1|1\.102\.'; then
            pass BGP.as21_primary_down 'AS21 obtained emergency transit through AS102'
        else
            fail BGP.as21_primary_down 'AS21 did not receive working transit through AS102'
        fi
        link_up as21r1 eth1
        if ! wait_ping as21h1 1.0.1.2 120; then
            fail BGP.as21_restore 'AS21 Internet access did not recover after restoring eth1'
        elif ! trace_excludes as21h1 1.0.1.2 '1\.102\.|2\.21\.0\.1'; then
            fail BGP.as21_restore 'AS21 still prefers AS102 after its primary link recovered'
        else
            pass BGP.as21_restore 'AS21 returned to its normal AS2 path'
        fi
    fi
}

preflight() {
    local missing=0 node command_name
    command -v kathara >/dev/null 2>&1 || { echo 'ERROR: kathara not found'; return 1; }
    for node in as102r1 as102r2 as102r3 as102r4 as102s1 as102c1 as21r1 as21h1; do
        kexec "$node" true >/dev/null 2>&1 || { echo "ERROR: node $node is not running"; missing=1; }
    done
    for command_name in traceroute ping ip; do
        kexec as102c1 which "$command_name" >/dev/null 2>&1 || {
            echo "ERROR: $command_name is unavailable inside as102c1"; missing=1;
        }
    done
    [ "$missing" -eq 0 ]
}

main() {
    local selected="${1:-all}"
    case "$selected" in
        all|same_path|igp_disruption|bgp_transit) ;;
        *) echo "Usage: $0 [all|same_path|igp_disruption|bgp_transit]"; exit 2;;
    esac
    preflight || exit 2
    case "$selected" in all|same_path) test_same_path;; esac
    case "$selected" in all|igp_disruption) test_igp_disruption;; esac
    case "$selected" in all|bgp_transit) test_bgp_transit;; esac
    printf '\nRESULT: PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}

main "$@"
