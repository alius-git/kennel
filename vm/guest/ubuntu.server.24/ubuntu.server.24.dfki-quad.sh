#!/bin/bash
# Version: 2026.08.05
# Kennel -- issue #10: take a fresh kennel-vm guest to "stack ready".
#
# Docker CE installed, the pinned dfki-quad fork cloned, upstream's Docker image
# built, the container started headless, and the go2 workspace compiled -- with
# no manual step in between, and idempotent on re-run.
#
# Runs via Yuruna's sshFetchAndExecute:
#   /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh
#
# fetch-and-execute passes NO arguments to the fetched script, so every knob
# below is an environment variable. They can be set on the sshExec command line
# ahead of the fetch-and-execute call, e.g.:
#   KENNEL_COLCON_JOBS=4 /usr/local/lib/yuruna/fetch-and-execute.sh guest/...
#
# Style follows guest/ubuntu.server.24/ubuntu.server.24.code.sh at Yuruna
# 2026.08.04: set -euo pipefail, the shared retry lib, apt_retry/curl_retry for
# every network call, and `==== name ====` banners -- which fetch-and-execute
# captures as per-phase timing checkpoints, so those banners ARE the wall-clock
# instrumentation issue #10 asks for.
#
# See vm/provisioning.md for the rationale, the deviations from upstream's own
# build_new_image.sh / run_docker.sh, and the measurement protocol.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: knobs
# The stack pin. Single source of truth is stack/pin.lock (issue #12); these two
# literals are a DERIVED COPY of its `fork:` and `commit:` and must be updated
# with it. They cannot read it: fetch-and-execute drops this script into the
# guest alone, with no checkout of the kennel repo to read. The drift check is
# the "Assert the clone sits at the stack pin" step in
# vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml, which re-states
# the SHA independently.
DFKI_QUAD_REPO="${DFKI_QUAD_REPO:-https://github.com/thalesasoares/dfki-quad}"
DFKI_QUAD_COMMIT="${DFKI_QUAD_COMMIT:-dcf53c596339afd45b82f12c54b1e93e8273c2f4}"
DFKI_QUAD_DIR="${DFKI_QUAD_DIR:-$HOME/dfki-quad}"
# Empty = colcon's default (= core count). Set to a number if the build OOMs;
# vm/guest-sizing.md section 6 makes capping parallelism the FIRST lever, ahead of
# raising guest RAM, because the host cannot give the guest much more.
KENNEL_COLCON_JOBS="${KENNEL_COLCON_JOBS:-}"
# Seconds the acceptance smoke lets the simulator run before stopping it.
KENNEL_SIM_SMOKE_SECONDS="${KENNEL_SIM_SMOKE_SECONDS:-45}"
# Set to 1 to force a rebuild of the Docker image even if it already exists.
KENNEL_FORCE_IMAGE_REBUILD="${KENNEL_FORCE_IMAGE_REBUILD:-0}"
# MUST default to OFF at this pin. state_estimation/CMakeLists.txt:11 declares
# `option(WITH_VICON "Use Vicon" ON)` and then does
# `find_package(vicon_receiver REQUIRED)`, but the image's Vicon install is
# COMMENTED OUT (docker/Dockerfile:154-158), so vicon_receiver is absent and the
# build fails at configure time. Vicon is lab motion-capture hardware and has no
# role in the go2 simulation, so OFF is also the semantically right value for
# the MVP. See vm/provisioning.md section 3.4.
KENNEL_WITH_VICON="${KENNEL_WITH_VICON:-OFF}"

CONTAINER_NAME=dfki_quad
IMAGE_NAME=dfki_quad

# --- REGION: in-container environment
# Sourced by EVERY in-container command this script runs. The image's
# /root/.bashrc sources the unitree_ros2 overlay, but .bashrc is only read by
# INTERACTIVE shells -- `docker exec ... bash -c` is not one, so without this
# the overlay is missing and `drivers` fails its configure with
# "Could not find a package configuration file provided by unitree_go".
# The overlay supplies unitree_go / unitree_api, which ROBOT_NAME=go2 needs.
# Guarded with -f so the script still works against an image that lays these
# out differently.
CONTAINER_ENV='source /opt/ros/humble/setup.bash
if [ -f /root/unitree_ros2/install/setup.bash ]; then source /root/unitree_ros2/install/setup.bash; fi'
METRICS_FILE="${KENNEL_METRICS_FILE:-$HOME/kennel-provisioning-metrics.txt}"
# Written only on a fully successful build of this exact pin; its presence is
# what makes phase 5 a no-op on re-run.
BUILD_STAMP="$DFKI_QUAD_DIR/ws/.kennel-built-$DFKI_QUAD_COMMIT"

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    # upstream build_new_image.sh maps x86_64 -> these two build args
    ARCH_BUILD_ARG="x86_64"
    GO2_NETWORK_INTERFACE="enp0s31f6"
    ;;
  *)
    # The MVP guest is amd64 (vm/guest-sizing.md section 1). aarch64 would need its own
    # validated numbers and upstream's aarch64 compose overlay, so refuse rather
    # than silently produce an unvalidated stack.
    echo "NONZERO SCRIPT EXIT: unsupported architecture '$ARCH'; the kennel MVP guest is x86_64." >&2
    exit 1
    ;;
esac

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
# Baked retry libs may bound apt attempts on wall-clock -- the wrapped-apt
# teardown-hang trap class. Force unbounded, as the stock guest scripts do.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

# --- REGION: measurement helpers (vm/guest-sizing.md section 5)
# Every number issue #9's section 5.4 table wants is captured here as a side effect of
# provisioning, so the table can be filled without a second instrumented run.
: > "$METRICS_FILE"
metric() {
    # metric <key> <value...>  -- echoed for the console AND appended to the file
    printf '%-34s %s\n' "$1" "${*:2}" | tee -a "$METRICS_FILE"
}
disk_used_gib() { df -BG --output=used / | tail -1 | tr -dc '0-9'; }
disk_avail_gib() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }

metric "run.started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
metric "guest.hostname" "$(hostname)"
metric "guest.nproc" "$(nproc)"
metric "guest.memtotal_mib" "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
metric "disk.used_gib.start" "$(disk_used_gib)"
metric "disk.avail_gib.start" "$(disk_avail_gib)"

echo ""
echo -e "\e[1;36m==== Docker CE ====\e[0m"
# --- REGION: https://yuruna.link/network#apt-signing-key-fingerprint-verification
# arg1 = key file; remaining args = ALLOWED primary fingerprints, FIRST also required.
# Lifted verbatim from ubuntu.server.24.code.sh so the kennel script trusts apt
# keys on exactly the same terms the stock guest scripts do.
_yuruna_verify_key_fpr() {
    local keyfile="$1"; shift
    local required="${1^^}" allowed=("$@") present a fpr ok found=0
    present="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
              | awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print toupper($10); p=0}}')"
    [ -n "$present" ] || { echo "!! key verify: no primary key fingerprints in $keyfile (is gpg installed?)" >&2; return 1; }
    while IFS= read -r fpr; do
        fpr="${fpr//[$'\r\n\t ']/}"; [ -z "$fpr" ] && continue
        ok=0; for a in "${allowed[@]}"; do [ "${a^^}" = "$fpr" ] && { ok=1; break; }; done
        [ "$ok" = 1 ] || { echo "!! key verify: unexpected fingerprint $fpr in $keyfile (not in the pinned allow-set)" >&2; return 1; }
        [ "$fpr" = "$required" ] && found=1
    done <<< "$present"
    [ "$found" = 1 ] || { echo "!! key verify: required fingerprint $required missing from $keyfile" >&2; return 1; }
    echo "  key verify: OK ($keyfile)"
}

if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    echo "Docker already installed and the daemon answers -- skipping install."
else
    apt_retry sudo apt-get install -y ca-certificates curl gnupg
    sudo install -d -m 0755 /etc/apt/keyrings
    curl_retry -fsSL "https://download.docker.com/linux/ubuntu/gpg${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/docker.asc
    # Docker's published release-key fingerprint. A mismatch means the key
    # served is not Docker's -- refuse rather than trust it into apt.
    _yuruna_verify_key_fpr /tmp/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 \
        || { echo "NONZERO SCRIPT EXIT: docker apt key fingerprint mismatch" >&2; rm -f /tmp/docker.asc; exit 1; }
    sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg < /tmp/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    rm -f /tmp/docker.asc

    # Pin the suite to the guest's own codename rather than hardcoding 'noble',
    # so this script keeps working if the guest image moves forward.
    . /etc/os-release
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt_retry sudo apt-get update
    apt_retry sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
fi

# Group membership is for an operator's later interactive session; it does NOT
# apply to the current SSH session, which is why every docker call in this
# script goes through sudo.
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    echo "Added $USER to the docker group (takes effect on the next login)."
fi

sudo docker --version
sudo docker info --format 'Docker daemon OK: {{.ServerVersion}}, storage={{.Driver}}, cpus={{.NCPU}}, mem={{.MemTotal}}'
metric "docker.version" "$(sudo docker --version)"

echo ""
echo -e "\e[1;36m==== dfki-quad clone at pin ====\e[0m"
# Pinned to a SHA, never a branch: issue #12 makes the pin the single source of
# truth every other MVP issue references, and a branch would silently drift.
if [ -d "$DFKI_QUAD_DIR/.git" ]; then
    current="$(git -C "$DFKI_QUAD_DIR" rev-parse HEAD)"
    if [ "$current" = "$DFKI_QUAD_COMMIT" ]; then
        echo "Already at the pin ($DFKI_QUAD_COMMIT) -- nothing to do."
    else
        echo "At $current, want $DFKI_QUAD_COMMIT -- refreshing."
        git -C "$DFKI_QUAD_DIR" -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 fetch --all --tags
        git -C "$DFKI_QUAD_DIR" checkout --detach "$DFKI_QUAD_COMMIT"
    fi
else
    # git ships no stall detection, so a clone stalled mid-transfer would hang
    # forever; the low-speed pair aborts a <1 KB/s-for-60s transfer into the
    # retry ladder instead (same treatment ubuntu.server.24.update.sh gives it).
    for attempt in 1 2 3; do
        git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 \
            clone "$DFKI_QUAD_REPO" "$DFKI_QUAD_DIR" && break
        echo "dfki-quad clone attempt $attempt failed"
        rm -rf "$DFKI_QUAD_DIR"
        [ $attempt -lt 3 ] && sleep 30
    done
    [ -d "$DFKI_QUAD_DIR/.git" ] || { echo "NONZERO SCRIPT EXIT: dfki-quad clone failed after 3 attempts" >&2; exit 1; }
    git -C "$DFKI_QUAD_DIR" checkout --detach "$DFKI_QUAD_COMMIT"
fi
git -C "$DFKI_QUAD_DIR" --no-pager log -1 --format='HEAD %H%n  %s'
metric "stack.pin" "$(git -C "$DFKI_QUAD_DIR" rev-parse HEAD)"

echo ""
echo -e "\e[1;36m==== dfki-quad image build ====\e[0m"
# DEVIATION from upstream's ./build_new_image.sh -- it opens with an
# interactive `read -s -n 1 key` prompt, so it can never complete under
# sshFetchAndExecute. What runs below is exactly the command that script
# derives for x86_64; only the prompt and the container-sweep are dropped.
# See vm/provisioning.md; recorded for #26 (bypasses) and #28 (upstream gaps).
if [ "$KENNEL_FORCE_IMAGE_REBUILD" != "1" ] && sudo docker image inspect "$IMAGE_NAME:latest" >/dev/null 2>&1; then
    echo "Image $IMAGE_NAME:latest already present -- skipping build."
    echo "  (force a rebuild with KENNEL_FORCE_IMAGE_REBUILD=1, or: sudo docker image rm $IMAGE_NAME)"
else
    disk_before_image="$(disk_used_gib)"
    sudo docker build -t "$IMAGE_NAME" "$DFKI_QUAD_DIR/docker" \
        --build-arg "HW_ARCH=${ARCH_BUILD_ARG}" \
        --build-arg "GO2_NETWORK_INTERFACE=${GO2_NETWORK_INTERFACE}"
    metric "disk.used_gib.after_image" "$(disk_used_gib)"
    metric "disk.delta_gib.image_build" "$(( $(disk_used_gib) - disk_before_image ))"
fi
metric "docker.image_size" "$(sudo docker image ls --format '{{.Size}}' "$IMAGE_NAME:latest" | head -1)"
sudo docker image ls "$IMAGE_NAME"
echo "--- docker system df ---"
sudo docker system df | tee -a "$METRICS_FILE"

echo ""
echo -e "\e[1;36m==== dfki-quad container ====\e[0m"
# DEVIATION from upstream's ./run_docker.sh -- headless-hostile three ways:
#   1. `xhost +local:`   -- no X server on a server guest.
#   2. `docker attach`   -- blocks forever and wants a TTY.
#   3. docker-compose.yml maps device /dev/ttyACM0, which does not exist in the
#      guest, so `docker compose up` fails outright. A compose OVERRIDE cannot
#      REMOVE a devices: entry, so compose cannot be salvaged from the outside.
# The docker run below reproduces the compose service minus those three, and
# minus the X11/DISPLAY, /dev/input and bash-history mounts (all irrelevant to a
# headless sim run). It KEEPS --network host, which is what will let #11 reach
# Meshcat from the host, and --privileged, matching upstream.
mkdir -p "$DFKI_QUAD_DIR/ws/build" "$DFKI_QUAD_DIR/ws/install" \
         "$DFKI_QUAD_DIR/ws/log" "$DFKI_QUAD_DIR/ws/data"

# Two traps here, both hit for real during #10's first run:
#   1. `inspect || echo absent` yields "\nabsent", not "absent" -- on a missing
#      object docker writes a newline to STDOUT before failing, so the case
#      below fell through to the catch-all and tried to start a container that
#      was never created.
#   2. `docker inspect NAME` also matches IMAGES, and the image is named
#      dfki_quad too. Without --type container it resolves the image, exits 0,
#      and '{{.State.Status}}' comes back empty -- "exists but is ''".
# --type container plus a separate existence probe removes both.
if sudo docker inspect --type container "$CONTAINER_NAME" >/dev/null 2>&1; then
    container_state="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null | tr -d '[:space:]')"
else
    container_state="absent"
fi
case "$container_state" in
    running)
        echo "Container $CONTAINER_NAME already running -- reusing it."
        ;;
    absent)
        sudo docker run -d -it \
            --name "$CONTAINER_NAME" \
            --label dfki_quad \
            --network host \
            --privileged \
            -w /root/ros2_ws \
            -v "$DFKI_QUAD_DIR/ws/src:/root/ros2_ws/src" \
            -v "$DFKI_QUAD_DIR/ws/build:/root/ros2_ws/build" \
            -v "$DFKI_QUAD_DIR/ws/install:/root/ros2_ws/install" \
            -v "$DFKI_QUAD_DIR/ws/log:/root/ros2_ws/log" \
            -v "$DFKI_QUAD_DIR/ws/data:/root/ros2_ws/data" \
            "$IMAGE_NAME:latest"
        ;;
    *)
        echo "Container $CONTAINER_NAME exists but is '$container_state' -- starting it."
        sudo docker start "$CONTAINER_NAME"
        ;;
esac

# No --restart policy, matching upstream: after a guest reboot the container is
# restarted explicitly with `sudo docker start dfki_quad` (documented for #11).
sudo docker ps --filter "name=$CONTAINER_NAME" --format 'container: {{.Names}} {{.Status}}'
sudo docker exec "$CONTAINER_NAME" bash -c 'test -f /root/setup_ulab_workspace.bash' \
    || { echo "NONZERO SCRIPT EXIT: /root/setup_ulab_workspace.bash missing in the image" >&2; exit 1; }
echo "setup_ulab_workspace.bash present (sim environment: FastRTPS, ROS_DOMAIN_ID=100)."

echo ""
echo -e "\e[1;36m==== colcon build go2 ====\e[0m"
# The build stamp records a COMPLETED build of this exact pin. colcon itself is
# incremental, so a re-run without the stamp is a cheap refresh rather than a
# rebuild -- the stamp exists to make the common case (already provisioned) a
# true no-op, not to prevent a refresh.
if [ -f "$BUILD_STAMP" ] && [ -f "$DFKI_QUAD_DIR/ws/install/setup.bash" ]; then
    echo "Workspace already built at this pin ($DFKI_QUAD_COMMIT) -- skipping."
    echo "  (stamp: $BUILD_STAMP; remove it to force a refresh)"
else
    # `time` is not in the ROS base image; the measurement protocol
    # (vm/guest-sizing.md section 5.1) needs /usr/bin/time -v for the largest single
    # compiler RSS. Installed into the container, not the guest.
    sudo docker exec "$CONTAINER_NAME" bash -c \
        'command -v /usr/bin/time >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq time)'

    # --- RAM sampling (vm/guest-sizing.md section 5.1)
    # The container shares the guest kernel and has no memory limit, so guest
    # /proc/meminfo sees the compilers' usage. MemAvailable (not MemFree) is the
    # right signal: it excludes reclaimable page cache, which a build inflates
    # without actually needing.
    rm -f /tmp/kennel-mem.log
    ( while :; do awk '/MemAvailable/{print systime(), $2}' /proc/meminfo; sleep 5; done ) > /tmp/kennel-mem.log &
    SAMPLER=$!
    # Stop the sampler even if the build fails, so a failed run still yields the
    # peak that explains why it failed.
    trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT

    colcon_extra=""
    if [ -n "$KENNEL_COLCON_JOBS" ]; then
        colcon_extra="--parallel-workers $KENNEL_COLCON_JOBS"
        echo "Capping colcon parallelism at $KENNEL_COLCON_JOBS (MAKEFLAGS too)."
    fi

    build_rc=0
    # The colcon line is issue #10's, plus the one addition that pin REQUIRES:
    # -DWITH_VICON=OFF (see the knob comment above -- without it the build fails
    # at configure time on a vicon_receiver the image does not ship). No `set -u`
    # inside: the ROS and colcon setup scripts read unbound variables.
    # PIPESTATUS carries the real exit code past `tee`.
    sudo docker exec "$CONTAINER_NAME" bash -c "
        set -eo pipefail
        ${KENNEL_COLCON_JOBS:+export MAKEFLAGS=-j$KENNEL_COLCON_JOBS}
        $CONTAINER_ENV
        cd /root/ros2_ws
        /usr/bin/time -v colcon build --symlink-install $colcon_extra \
            --cmake-args -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -DROBOT_NAME=go2 \
            -DWITH_VICON=$KENNEL_WITH_VICON 2>&1 | tee /tmp/colcon.log
        exit \${PIPESTATUS[0]}
    " || build_rc=$?

    kill "$SAMPLER" 2>/dev/null || true
    trap - EXIT

    # Peak = MemTotal - min(MemAvailable) across the whole build.
    if [ -s /tmp/kennel-mem.log ]; then
        metric "ram.peak_used_gib" "$(awk -v tot="$(awk '/MemTotal/{print $2}' /proc/meminfo)" \
            'NR==1||$2<min{min=$2} END{printf "%.1f", (tot-min)/1048576}' /tmp/kennel-mem.log)"
    fi
    rss_kib="$(sudo docker exec "$CONTAINER_NAME" bash -c "grep 'Maximum resident set size' /tmp/colcon.log | tail -1" 2>/dev/null \
               | tr -dc '0-9')"
    metric "ram.largest_compiler_rss_kib" "${rss_kib:-n/a}"
    # The failure this sizing exists to prevent. Recorded either way.
    # sudo is required: Ubuntu 24.04 sets kernel.dmesg_restrict=1, so an
    # unprivileged dmesg returns nothing and would report a false "none" -- the
    # exact reading this check exists to catch.
    if sudo dmesg -T 2>/dev/null | grep -qi 'out of memory\|oom-kill'; then
        metric "ram.oom_kills" "PRESENT -- see dmesg (vm/guest-sizing.md section 6)"
        sudo dmesg -T | grep -i 'out of memory\|oom-kill' | tail -5
    else
        metric "ram.oom_kills" "none"
    fi

    if [ "$build_rc" -ne 0 ]; then
        echo "NONZERO SCRIPT EXIT: colcon build failed (exit $build_rc)." >&2
        echo "  Build log: /tmp/colcon.log inside the container." >&2
        echo "  If this was an OOM, vm/guest-sizing.md section 6 says cap parallelism FIRST:" >&2
        echo "    KENNEL_COLCON_JOBS=4 /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh" >&2
        exit "$build_rc"
    fi

    date -u +%Y-%m-%dT%H:%M:%SZ > "$BUILD_STAMP"
fi

metric "disk.used_gib.after_colcon" "$(disk_used_gib)"
metric "workspace.size" "$(du -sh "$DFKI_QUAD_DIR" 2>/dev/null | cut -f1)"

echo ""
echo -e "\e[1;36m==== verify sim launchable ====\e[0m"
# Issue #10's acceptance criterion: `ros2 launch simulator simulator.launch.py
# sim:=go2` is launchable inside the container with no manual step in between.
# This is a BOUNDED smoke test -- the full walking/health verification is #13
# and #14. The assertion is that the launch is still alive after the smoke
# window: a stack that failed to build, or whose environment is wrong, exits
# within seconds instead.
sim_log=/tmp/kennel-sim-smoke.log
set +e
sudo docker exec "$CONTAINER_NAME" bash -c "
    $CONTAINER_ENV
    source /root/ros2_ws/install/setup.bash
    source /root/setup_ulab_workspace.bash
    # Teardown must be BOUNDED and must never use a negative (process-group)
    # signal. Two failures shaped this:
    #   1. 'wait \$LP' after SIGINT hung a run for 83 minutes -- the Drake
    #      simulator does not reliably exit when only the launcher is signalled.
    #   2. 'kill -\$LP' with setsid killed this shell's own group instead: \$! is
    #      the setsid PID, which is not dependably the new group leader.
    # So: signal the launcher, wait a bounded interval, then hard-kill the
    # launcher and its known children BY PATTERN. Cannot misfire on our own tree.
    ros2 launch simulator simulator.launch.py sim:=go2 > /tmp/sim-smoke.log 2>&1 &
    LP=\$!
    sleep $KENNEL_SIM_SMOKE_SECONDS
    if ! kill -0 \$LP 2>/dev/null; then
        echo 'SIM_SMOKE: launch exited early'
        exit 1
    fi
    echo 'SIM_SMOKE: still running after $KENNEL_SIM_SMOKE_SECONDS s'
    kill -INT \$LP 2>/dev/null || true
    for _ in \$(seq 1 10); do kill -0 \$LP 2>/dev/null || break; sleep 1; done
    kill -KILL \$LP 2>/dev/null || true
    # Reap the node processes so the next run's port 7000 is free.
    # -x matches the exact process NAME, never the command line: a -f pattern
    # containing 'ros2 launch simulator' also matches THIS shell, whose cmdline
    # contains that very text, and kills the teardown mid-flight.
    pkill -KILL -x simulator 2>/dev/null || true
    pkill -KILL -x ros2 2>/dev/null || true
    exit 0
"
smoke_rc=$?
set -e
sudo docker exec "$CONTAINER_NAME" bash -c 'cat /tmp/sim-smoke.log' > "$sim_log" 2>/dev/null || true
echo "--- simulator launch output (first 60 lines) ---"
head -60 "$sim_log" || true
echo "--- end ---"

# Meshcat's URL is what #11 has to expose to the host browser; capture it here
# so #11 starts from an observed value rather than an assumed one.
meshcat_url="$(grep -oiE 'http://[^ ]*:7[0-9]{3}[^ ]*' "$sim_log" 2>/dev/null | head -1 || true)"
if [ -n "$meshcat_url" ]; then
    metric "meshcat.url_in_container" "$meshcat_url"
else
    metric "meshcat.url_in_container" "not printed in the smoke window (see $sim_log; feeds #11)"
fi

if [ "$smoke_rc" -ne 0 ]; then
    echo "NONZERO SCRIPT EXIT: the simulator launch did not survive the smoke window." >&2
    echo "  Full output: $sim_log (guest) / /tmp/sim-smoke.log (container)" >&2
    exit 1
fi
metric "sim.smoke" "PASS (alive after ${KENNEL_SIM_SMOKE_SECONDS}s)"

echo ""
echo -e "\e[1;36m==== summary ====\e[0m"
metric "disk.used_gib.end" "$(disk_used_gib)"
metric "disk.avail_gib.end" "$(disk_avail_gib)"
metric "run.ended" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "Stack ready. Metrics for vm/guest-sizing.md section 5.4 are in $METRICS_FILE:"
echo ""
cat "$METRICS_FILE"
echo ""
echo "Launch the simulator by hand with:"
echo "  sudo docker exec -it $CONTAINER_NAME bash"
echo "  source /root/setup_ulab_workspace.bash   # alias: sr"
echo "  ros2 launch simulator simulator.launch.py sim:=go2"
echo ""
echo -e "\e[1;32m==== dfki-quad stack ready. ====\e[0m"
