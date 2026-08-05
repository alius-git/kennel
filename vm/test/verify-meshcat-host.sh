#!/bin/bash
# Version: 2026.08.05
# Kennel -- issue #11: prove Meshcat (served inside the guest's container) is
# reachable from the HOST browser, and print the URL to open.
#
# Runs on the HOST, not in the guest. Yuruna has no host-exec action -- its
# verbs are sshExec / sshFetchAndExecute / callExtension (test/sequences/actions.yml)
# -- so the guest->host hop cannot be asserted from inside a sequence. The
# in-cycle assertion covers the container->guest hop instead (see
# workload.guest.ubuntu.server.24.kennel.stack.ssh.yml); this script covers the
# hop that only the host can see.
#
# Read-only: it discovers, curls and reports. It never starts, stops or
# reconfigures anything -- so it is safe to run against a guest mid-build.
#
# Usage:
#   vm/test/verify-meshcat-host.sh              # discover everything, verify
#   vm/test/verify-meshcat-host.sh --quiet      # print only the final URL
#
# Exit codes are distinct on purpose -- each failure mode has a different fix:
#   0  Meshcat reachable from the host; last stdout line is the URL
#   2  guest IP could not be discovered      (guest down? wrong network?)
#   3  guest unreachable over SSH            (key? boot not finished?)
#   4  no Meshcat listener in the guest      (simulator not running -- launch it)
#   5  listener is loopback-only             (the documented contingency)
#   6  port open from the host but content is not Meshcat
#   7  listener present but NOT reachable from the host (routing/firewall)
#
# See vm/meshcat-exposure.md for the two-hop model and the recipes.

set -uo pipefail

# --- REGION: knobs
GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"   # as it appears in the DHCP lease
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
# Set to the libvirt DOMAIN name to skip lease lookup. NB the domain is named
# test-guest.ubuntu.server.24-01 by Yuruna -- `kennel-vm` is the guest's
# HOSTNAME, not its domain name. Hence lease-by-hostname as the primary path.
GUEST_DOMAIN="${KENNEL_VM_DOMAIN:-}"
GUEST_IP="${KENNEL_GUEST_IP:-}"
CURL_TIMEOUT="${KENNEL_CURL_TIMEOUT:-10}"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = 1 ] || echo "$@"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

# --- REGION: hop 2, part 1 -- find the guest on the libvirt NAT network
if [ -z "$GUEST_IP" ]; then
    # Primary path: the DHCP lease table carries the guest's HOSTNAME, so this
    # works without knowing Yuruna's generated domain name.
    GUEST_IP="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
                | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
                | cut -d/ -f1 | tail -1)"
fi
if [ -z "$GUEST_IP" ] && [ -n "$GUEST_DOMAIN" ]; then
    GUEST_IP="$(virsh domifaddr "$GUEST_DOMAIN" --source lease 2>/dev/null \
                | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)"
fi
if [ -z "$GUEST_IP" ]; then
    fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
         "Is the guest running?   virsh list --all" \
         "Leases:                 virsh net-dhcp-leases $LIBVIRT_NET" \
         "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0"
    exit 2
fi
say "guest            $GUEST_HOSTNAME at $GUEST_IP (libvirt '$LIBVIRT_NET')"

# --- REGION: hop 1 -- what did Meshcat actually bind, inside the guest?
# The container runs --network host (vm/provisioning.md 3.2), so a listener
# opened in the container is a listener in the GUEST's network namespace and
# `ss` on the guest sees it. Drake picks the first free port in 7000-7099, so
# the port is discovered, never assumed.
# The trailing `|| true` is deliberate: with no listener, grep exits 1 and the
# remote command would return non-zero, which is indistinguishable from "SSH
# failed" -- and the two need different diagnoses. (It happens to work without
# it because `sort -u` is last and exits 0 on empty input, but relying on that
# is exactly the kind of accident that breaks when the pipeline is edited.)
listener="$(ssh "${SSH_OPTS[@]}" "$GUEST_USER@$GUEST_IP" \
            "ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -E ':7[0-9]{3}\$' | sort -u || true" 2>/dev/null)"
ssh_rc=$?
if [ "$ssh_rc" -ne 0 ] && [ -z "$listener" ]; then
    fail "cannot reach the guest over SSH at $GUEST_USER@$GUEST_IP (rc=$ssh_rc)." \
         "Key: $SSH_KEY" \
         "Try: ssh -i $SSH_KEY $GUEST_USER@$GUEST_IP hostname"
    exit 3
fi

if [ -z "$listener" ]; then
    fail "no listener on 7000-7099 in the guest -- the simulator is not running." \
         "Meshcat only exists while the sim does. Start it (detached) with:" \
         "  ssh -i $SSH_KEY $GUEST_USER@$GUEST_IP \\" \
         "    \"sudo docker start dfki_quad; sudo docker exec -d dfki_quad bash -c '" \
         "       source /opt/ros/humble/setup.bash;" \
         "       source /root/unitree_ros2/install/setup.bash;" \
         "       source /root/ros2_ws/install/setup.bash;" \
         "       source /root/setup_ulab_workspace.bash;" \
         "       ros2 launch simulator simulator.launch.py sim:=go2 > /tmp/sim.log 2>&1'\"" \
         "then re-run this script. See vm/meshcat-exposure.md 3."
    exit 4
fi

# Loopback-only is the documented contingency: with --network host the
# container's loopback IS the guest's loopback, so nothing outside can reach it.
if ! grep -qvE '^(127\.|\[::1\])' <<< "$listener"; then
    fail "Meshcat is bound LOOPBACK-ONLY in the guest -- unreachable from the host." \
         "Listeners seen: $(tr '\n' ' ' <<< "$listener")" \
         "Workaround (SSH tunnel from the host), then browse http://localhost:7000 :" \
         "  ssh -i $SSH_KEY -N -L 7000:127.0.0.1:${listener##*:} $GUEST_USER@$GUEST_IP" \
         "NB 127.0.0.1, NOT localhost: the forward target is resolved IN THE GUEST," \
         "where 'localhost' is ::1 only, so the localhost form resets the connection." \
         "See vm/meshcat-exposure.md 6.1 -- and file it, the binding changed."
    exit 5
fi

PORT="$(grep -vE '^(127\.|\[::1\])' <<< "$listener" | head -1 | sed 's/.*://')"
say "listener         $(tr '\n' ' ' <<< "$listener") -- non-loopback, port $PORT"

# --- REGION: hop 2, part 2 -- reach it from the host
URL="http://$GUEST_IP:$PORT/"
body="$(curl -fsS --max-time "$CURL_TIMEOUT" "$URL" 2>/dev/null)"
curl_rc=$?
if [ "$curl_rc" -ne 0 ]; then
    fail "the listener exists in the guest but the host cannot reach $URL (curl rc=$curl_rc)." \
         "The host routes to the guest over virbr0; check it is up and unfiltered:" \
         "  ip -br addr show virbr0" \
         "  sudo iptables -L LIBVIRT_FWI -n"
    exit 7
fi

if ! grep -qi 'meshcat' <<< "$body"; then
    fail "$URL answered, but the content is not Meshcat." \
         "Something else is on port $PORT. First 200 bytes:" \
         "$(head -c 200 <<< "$body" | tr '\n' ' ')"
    exit 6
fi

say "content          HTTP 200, Meshcat page ($(wc -c <<< "$body") bytes)"
say ""
say "Meshcat is reachable from this host. Open in the host browser:"
echo "$URL"
