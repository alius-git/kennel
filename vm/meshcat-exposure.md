# Meshcat from the host browser — the two hops

Implementation record for
[issue #11](https://github.com/alius-git/kennel/issues/11) — the Drake/Meshcat
visualization served by the simulator **inside the container, inside the guest**
is opened from a browser **on the host**.

Builds directly on [`vm/provisioning.md`](provisioning.md)
([#10](https://github.com/alius-git/kennel/issues/10)), which already chose
`--network host` for the container with this issue named as the reason, and on
[`vm/host-baseline.md`](host-baseline.md) §5
([#8](https://github.com/alius-git/kennel/issues/8)) for the libvirt NAT layout.

> **Bypass note** (tracking-issue [#7](https://github.com/alius-git/kennel/issues/7),
> [#26](https://github.com/alius-git/kennel/issues/26)): [`plan/design.md`](../plan/design.md)
> §1 specifies the console — and the Meshcat iframe inside it — reached "from the
> host browser via a **forwarded port**". This issue delivers the MVP stand-in:
> the guest's NAT address is reached **directly**, with no forward configured.
> Same outcome for the operator (a URL in the host browser), one less moving
> part. *Retirement path:* §7.2 — a libvirt/hypervisor port forward, which is
> also what the OVA/VirtualBox appliance will need, since its default networking
> gives no route to the guest.

## 1. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`vm/test/verify-meshcat-host.sh`](test/verify-meshcat-host.sh) | Host-side check: discovers the guest, the port and the binding, curls Meshcat, prints the URL to open |
| A new step in [`test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml`](../test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml) | In-cycle assertion of hop 1 (see §2) |
| §3 and §4 of this document | The URL recipe and the reboot recipe — the written-down artifact the issue asks for, feeding [#27](https://github.com/alius-git/kennel/issues/27) |

## 2. The two hops

```
  [ Drake / Meshcat ]  in the container
          |  hop 1: --network host  -> no hop at all, same netns as the guest
  [ kennel-vm guest ]  192.168.122.x on libvirt 'default'
          |  hop 2: libvirt NAT     -> the host routes to it over virbr0
  [ host browser ]     http://192.168.122.x:7000/
```

### 2.1 Hop 1, container → guest: already solved by #10, and it is a no-op

The container runs with `--network host`
([`vm/provisioning.md` §3.2](provisioning.md)), so it shares the guest's network
namespace outright. A socket Meshcat opens **is** a socket in the guest; there
is no publishing, mapping or `-p` flag involved, and `ss` on the guest sees the
listener directly.

So issue #11's first work item — "Docker run flags / host networking in
upstream's `run_docker.sh`" — resolves to **verify, not implement**. The
verification is what §5 records. What still had to be established is that
Meshcat binds a *non-loopback* address, because with `--network host` a
loopback-bound listener is bound to the **guest's** loopback and is just as
unreachable (§6.1 is the contingency for that).

### 2.2 Hop 2, guest → host: direct NAT address, no forward

The guest sits on libvirt's `default` NAT network at `192.168.122.0/24`, and the
host holds `192.168.122.1` on `virbr0` — so the host already has a route to the
guest, and any address the guest binds on that interface is reachable from the
host with **no port forward, no firewall change and no `virsh` reconfiguration**.

This was verified independently of Meshcat, with a throwaway listener, before
the stack was even built (§5.1) — worth doing, because it separates "is the
network path open" from "did Drake bind the right thing", and those two fail for
completely different reasons.

A forward would only be needed to reach the guest from a **third machine**, and
that is out of scope for the MVP: [`plan/design.md`](../plan/design.md) §2 puts
the browser on the host. §7.2 records it as the growth path.

## 3. The URL recipe

**The one-command form** — run it on the host, with the simulator running in the
guest:

```bash
vm/test/verify-meshcat-host.sh
```

It prints the URL to open as its **last line**, and exits non-zero with a
specific diagnosis if any part of the chain is down (§3.3).

**The manual form**, for an operator who wants to see each step:

```bash
# 1. Find the guest on the NAT network. NB: match on the guest's HOSTNAME --
#    the libvirt DOMAIN is called test-guest.ubuntu.server.24-01, not kennel-vm.
virsh net-dhcp-leases default | grep kennel-vm
#   -> 192.168.122.8

# 2. Find the port Meshcat actually took (do NOT assume 7000 -- see §4.3).
ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 yuuser24@192.168.122.8 \
  "ss -tlnH | awk '{print \$4}' | grep -E ':7[0-9]{3}\$'"
#   -> *:7000        (Drake binds all interfaces; the sim's own log line
#                      says "localhost", which understates it -- see §5.2)

# 3. Open it in the host browser.
xdg-open http://192.168.122.8:7000/
```

### 3.1 Naming trap: `kennel-vm` is not the domain name

`virsh domifaddr kennel-vm` **fails** — Yuruna names the libvirt domain
`test-guest.ubuntu.server.24-01`, while `kennel-vm` is the *hostname* set inside
the guest ([`vm/guest-sizing.md` §2](guest-sizing.md)). The DHCP lease table
carries the hostname, which is why the recipe and the script both match on the
lease rather than on the domain. `verify-meshcat-host.sh` still accepts
`KENNEL_VM_DOMAIN=` for the `domifaddr` path when the lease has expired.

### 3.2 Getting the simulator running in the first place

Meshcat exists only while the simulator does — it is served *by* the sim
process, so there is nothing listening before launch and nothing after teardown.
Launch it **detached** (`docker exec -d`), so it survives the SSH session
closing:

```bash
ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 yuuser24@192.168.122.8 \
  "sudo docker exec -d dfki_quad bash -c '
     source /opt/ros/humble/setup.bash
     source /root/unitree_ros2/install/setup.bash
     source /root/ros2_ws/install/setup.bash
     source /root/setup_ulab_workspace.bash
     exec ros2 launch simulator simulator.launch.py sim:=go2 > /tmp/sim.log 2>&1'"
```

All four `source` lines are required, and the second is the one that is easy to
miss: `docker exec` is not an interactive shell, so the image's `.bashrc` — which
is where upstream sources the `unitree_ros2` overlay — is never read. Without it
the go2 driver nodes cannot resolve `unitree_go` and the launch dies in seconds.
[`vm/provisioning.md` §3.5](provisioning.md) has the full account.

### 3.3 When it does not work

`verify-meshcat-host.sh` exits with a distinct code per failure mode, because
each has a different fix:

| Exit | Meaning | First thing to do |
|------|---------|-------------------|
| 2 | Guest IP not discoverable | `virsh list --all` — is the guest running? |
| 3 | Guest not reachable over SSH | Has it finished booting? Right key? |
| 4 | No listener on 7000–7099 | The simulator is not running — §3.2 |
| 5 | Meshcat bound loopback-only | §6.1 (tunnel workaround) |
| 6 | Port answers but is not Meshcat | Something else took the port — §4.3 |
| 7 | Listener exists, host cannot reach it | `virbr0` down or filtered — §6.3 |

## 4. Surviving a guest reboot

The issue's acceptance criterion says the recipe must survive a guest reboot. It
does, but **not by itself** — two things do not come back on their own, and both
are deliberate upstream-matching choices from #10 rather than oversights.

### 4.1 What does and does not survive

| Thing | Survives a reboot? | Why |
|-------|--------------------|-----|
| Guest IP `192.168.122.8` | Yes, in practice | libvirt's DHCP re-issues by MAC; the MAC is fixed in the domain XML |
| Docker daemon | Yes | `systemctl enable --now docker` at provisioning time |
| The `dfki_quad` container | **No** | **no `--restart` policy**, matching upstream ([`vm/provisioning.md` §3.2](provisioning.md)) |
| The simulator + Meshcat | **No** | it is a foreground process, not a service |
| The built workspace | Yes | the five `ws/` bind mounts live on the guest filesystem |

### 4.2 The post-reboot recipe

```bash
# on the host, after `virsh reboot test-guest.ubuntu.server.24-01`
# 1. wait for sshd, then restart the container (it has no restart policy)
ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 yuuser24@192.168.122.8 \
  "sudo docker start dfki_quad"

# 2. relaunch the simulator -- §3.2's detached form, verbatim

# 3. re-verify. The IP is re-discovered, so this is correct even if it moved.
vm/test/verify-meshcat-host.sh
```

Step 3 re-discovers the address rather than trusting §3's value, which is the
reason the recipe survives the reboot even in the case where the lease *does*
change. §6.2 covers pinning the address if that ever becomes a nuisance.

### 4.3 The port is discovered, never assumed

Drake's Meshcat takes **the first free port in 7000–7099**, so `7000` is the
usual answer, not a guaranteed one. A simulator from an earlier run that was not
reaped still holds 7000, and the next launch quietly lands on 7001 — at which
point a hardcoded URL shows a stale scene or nothing at all.

Everything here therefore discovers the port: the script, the sequence step and
the manual recipe all read it from `ss`. If you find Meshcat on a port other
than 7000, suspect a leftover simulator first:

```bash
ssh ... yuuser24@192.168.122.8 \
  "sudo docker exec dfki_quad bash -c 'pkill -KILL -x simulator; pkill -KILL -x ros2'"
```

Reap by **exact process name** (`-x`). `pkill -f 'ros2 launch simulator'` is a
trap: the shell running it has that string in its own command line, so it kills
itself mid-teardown. [`vm/provisioning.md` §5a](provisioning.md) records the
83-minute hang that established this, and it bit again during this issue's work
(§5.1).

## 5. Validation — evidence

All on 2026-08-05, against the guest provisioned by #10's first clean
uninterrupted pass (27/27 steps green — the run provisioning.md §5a had listed
as outstanding).

### 5.1 Hop 2 proven before the stack existed

Run on 2026-08-05 against the `kennel-vm` guest while its Docker image was still
building, using a throwaway listener rather than Meshcat — so the *network path*
is established independently of anything Drake does.

| Check | Command | Result |
|-------|---------|--------|
| Guest discoverable by hostname | `virsh net-dhcp-leases default` | `192.168.122.8`, hostname `kennel-vm` |
| Host → guest, non-loopback bind | `python3 -m http.server 7000 --bind 0.0.0.0` in the guest, then `curl` from the host | **200 OK, body served** — no port forward, no firewall change |
| Loopback bind is correctly rejected | same, `--bind 127.0.0.1` | script exits 5 `MESHCAT_LOOPBACK_ONLY` |
| Sequence step, positive path | step logic with `docker` stubbed, fake listener on **7005** | `MESHCAT_OK http://192.168.122.8:7005/`, exit 0 — and it found 7005, so the port really is discovered |
| Sequence step, loopback path | same, bound to `127.0.0.1` | `MESHCAT_LOOPBACK_ONLY`, exit 1 |

Doing this early separated the network question from the Drake question, and it
also surfaced two of the §5.5 defects before Meshcat ever ran.

### 5.2 Hop 1 and the rendered scene — live stack

**Acceptance met.** With `ros2 launch simulator simulator.launch.py sim:=go2`
running in the container:

| Check | Result |
|-------|--------|
| Binding in the guest | `ss -tlnp` → **`*:7000`** — all interfaces, no workaround needed |
| What Drake *prints* | `Meshcat listening for connections at http://localhost:7000` |
| `verify-meshcat-host.sh` | exit 0 → `http://192.168.122.8:7000/` |
| Page from the host | HTTP 200, 10 039 bytes, Meshcat HTML |
| WebSocket from the host | `101 Switching Protocols`, **33 020 bytes of scene data pushed** unprompted on attach |
| Rendered scene from the host | headless Chrome screenshot: grid, axis triad, force-arrow visualizers, go2 model geometry, Meshcat controls — [`meshcat-host-render.png`](meshcat-host-render.png) |

The printed URL and the real binding **disagree**, and the binding is the
generous one: Drake constructs `Meshcat` with default params
(`ws/src/simulator/src/drake_simulator.cpp:438`), which bind `*` but print
`localhost`. So the `meshcat.url_in_container` metric #10 captures is the right
*port* and the wrong *host part* — trust `ss`, not the log line. The WebSocket
check matters because HTTP 200 only proves the static page: the scene itself
arrives over the WS, so a page-only check could pass while the browser shows
void.

### 5.3 Reboot survival

`virsh reboot test-guest.ubuntu.server.24-01`, then §4.2's recipe verbatim:

| Step | Result |
|------|--------|
| Guest returns | same IP `192.168.122.8` (MAC-pinned lease, §4.1) |
| Container state after boot | `exited` — as §4.1 predicts (no restart policy) |
| `sudo docker start dfki_quad` | up |
| Relaunch (§3.2, verbatim) | Meshcat back on `*:7000` |
| `verify-meshcat-host.sh` | **exit 0, same URL**, HTTP 200 |

### 5.4 The in-cycle assertion, in a real cycle

The sequence step delivered in §1 (sequence revision 2) ran inside an actual
Yuruna cycle against the provisioned guest: `Test-Config.ps1 -SkipSend` at the
expected 34 PASS / 4 WARN / 0 FAIL baseline, then
`Invoke-TestSequence.ps1 ... -StartStep 18` green on all 11 stack steps:

```
 57 s [ 3/11] PASS sshFetchAndExecute: Provision Docker + the pinned dfki-quad stack
 57 s [ 4/11] PASS sshFetchAndExecute: Re-run to prove idempotency (must be a no-op refresh)
 56 s [ 9/11] PASS sshExec: Assert 'ros2 launch simulator ... sim:=go2' is launchable
  3 s [10/11] PASS sshExec: Assert Meshcat binds a host-reachable address in the guest (#11 hop 1)
175 s [All 11 steps completed in 3 min and 55 s]
```

Steps 3–4 at ~57 s each are #10's idempotency guards holding (a re-provision on
a built guest is a refresh, not a rebuild); step 10 is this issue's assert
passing against a simulator the step launched and reaped itself. The 3 s tells
its own small story: Drake constructs Meshcat early in node startup, well
before the controllers settle, so the listener is there almost immediately.

### 5.5 Trap log — found by testing, not reasoning

Recorded in the same spirit as provisioning.md §5a's defect table: each of these
survived a careful first writing and died only on execution.

1. **The SSH-tunnel workaround in §6.1 was wrong as first written.**
   `-L 7000:localhost:7000` resolves `localhost` **in the guest**, where
   `getent hosts localhost` returns `::1` *only* — so the forward targets
   `[::1]:7000` while the listener is on IPv4 `127.0.0.1:7000`, and every
   request dies with `Recv failure: Connection reset by peer`. Verified: the
   `127.0.0.1` form works, the `localhost` form does not. The script emits the
   `127.0.0.1` form and says why.
2. **Pattern-matching your own command line, three separate times** — the trap
   class provisioning.md §5a defect 5 documents, reproduced independently
   thrice in one working session: `pkill -f "http.server 7000"` killed the
   shell that issued it; `pkill -f "L 1700"` likewise; and a watcher loop of
   the form `while pgrep -f "Invoke-TestSequence.ps1"` **never terminates**,
   because pgrep's match set includes the watcher itself. Kill and poll by
   exact process name (`-x`) or by PID — never by command-line substring.
3. **`grep` as the last real filter in a `$(...)` assignment under `set -e`**
   aborts the script on the legitimate "nothing found yet" case (grep exits 1),
   turning a poll loop into a crash. Every discovery pipeline here therefore
   ends `|| true` and tests emptiness explicitly.

## 6. Contingencies

### 6.1 Meshcat binds loopback-only

Not the observed behaviour (§5), but the issue asks for the workaround to be
documented, and a future repin could change Drake's default. With
`--network host` the container's loopback *is* the guest's loopback, so this is
purely a guest→host problem and an SSH tunnel solves it from the host alone:

```bash
ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 \
    -N -L 7000:127.0.0.1:7000 yuuser24@192.168.122.8
# then browse http://localhost:7000/
```

**Use `127.0.0.1`, not `localhost`** — see §5.1 defect 1; the `localhost` form
silently fails on this guest.

A guest-side alternative, if the tunnel is unwanted (a relay from the NAT address
to loopback, no host-side process):

```bash
socat TCP-LISTEN:7000,bind=192.168.122.8,fork TCP:127.0.0.1:7000
```

If this contingency is ever needed, it is an upstream-shaped finding — Drake's
`MeshcatParams` would have to be constructed with a non-default `host` — and
belongs on [#28](https://github.com/alius-git/kennel/issues/28).

### 6.2 The guest IP changes across reboots

The recipe re-discovers the address every time, so this is a nuisance rather
than a failure. To pin it, add a static lease to the libvirt network:

```bash
virsh net-update default add ip-dhcp-host \
  "<host mac='52:54:00:20:55:4c' name='kennel-vm' ip='192.168.122.8'/>" \
  --live --config
```

Deliberately **not** applied: it is host state that the repo does not otherwise
own, and nothing has needed it.

### 6.3 The host cannot reach a listener that exists

Means the NAT path, not Meshcat, is broken. Check `virbr0` is up and that
libvirt's forward chain is not filtering:

```bash
ip -br addr show virbr0                 # expect UP, 192.168.122.1/24
sudo iptables -L LIBVIRT_FWI -n         # expect the 192.168.122.0/24 ACCEPT
virsh net-list --all                    # expect default active + autostart
```

## 7. Notes for the record

- **`--network host` is doing the load-bearing work here**, and it is upstream's
  choice rather than one this issue made. It also means the container has **no
  network isolation** from the guest ([`vm/provisioning.md` §8](provisioning.md)).
  Acceptable for an MVP appliance on a NAT'd guest; it should not be inherited
  silently into the shipped image without a second look.
- **The guest→host hop is not asserted inside the Yuruna cycle.** Yuruna's
  action vocabulary is `sshExec` / `sshFetchAndExecute` / `callExtension`
  (`test/sequences/actions.yml`) — all of which execute in the *guest*. There is
  no host-exec verb, so the hop that only the host can see is covered by
  `verify-meshcat-host.sh`, run by hand. Worth raising on
  [#28](https://github.com/alius-git/kennel/issues/28) as a framework gap: a
  `hostExec` action would let this be a cycle assertion.
- **This is the seam the console will use.** [`plan/design.md`](../plan/design.md)
  §1 embeds Meshcat as an iframe inside the console, and §3 serves the console
  from inside the VM. Both then reduce to the same question this issue answers —
  which address does the host browser use — so the console work inherits §3's
  recipe rather than re-deriving it.
- **`vm/test/` now holds a host-side script**, whereas everything else there is a
  Yuruna sequence copied into the framework clone. `verify-meshcat-host.sh` is
  **not** copied anywhere: it runs from the kennel checkout. The naming keeps
  the `vm/test/` grouping, but the deployment story is different.

---

Last review: 2026-08-05
