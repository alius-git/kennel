# First run — a walking robot in eight steps

Eight steps, each one command or one click. Follow them in order and add
nothing: everything you need is on this page.

**What this assumes.** A host where `demo/tools/kennel-demo.sh setup` and
`demo/tools/kennel-demo.sh provision` have already been run once, so the
`kennel-vm` guest exists — powered on or off, either is fine. A terminal at the
root of this repository. Nothing else.

**What it does not cover yet.** Importing the appliance image and booting
straight into this page is [issue #76](https://github.com/alius-git/kennel/issues/76);
until that lands, a provisioned guest is the starting line.

If a step does not do what it says, do not improvise — every step below is
performed and timed by `demo/tools/kennel-demo.sh scenario firstwalk`, and a
step that fails there is a bug in this page. `demo/tools/kennel-demo.sh reset`
returns the guest to its baseline in about ninety seconds, and you can start
again from step 1.

---

### 1 · Serve the console

```bash
demo/tools/kennel-demo.sh console
```

It serves the console and opens it in your browser.

**Success looks like:** the URL it prints ends in `Kennel%20Console.dc.html`,
and that page is open in your browser on the **Compose** view.

### 2 · Load the stock preset

In the toolbar at the top right, open **load preset…** and pick
**Stock Go2 walk**.

```click
preset Stock Go2 walk
```

This is every choice at the value the pinned stack itself uses — the safe
first run. The other three presets are for later; the walkthrough explains
them.

**Success looks like:** the line under the toolbar reads `preset · Stock Go2 walk`,
and the MPC block in the pipeline reads *HPIPM · partial condensing*.

### 3 · Send the run to the host

Click **send to kennel-runs →**.

```click
send
```

The console does not launch anything, ever. It writes a folder — two config
files, the launch commands, and a record of what you chose — where the next
step will look for it.

**Success looks like:** the strip under the buttons reads `saved` followed by
the folder it wrote, something like `/home/you/kennel-runs/run-20260909T181657Z`.

### 4 · Run it

```bash
demo/tools/kennel-demo.sh run
```

It takes the run you just sent, copies it into the guest, launches the stack,
checks ten things about it, and leaves the robot trotting. Give it about a
minute and a half. (It starts the guest first if it was powered off — you do
not have to notice.)

**Success looks like:** it names the run it picked and why, then ends with
`pass=10 fail=0` and a Meshcat URL. Open that URL in a second tab if you want
to watch — it is the simulator's own 3D view.

### 5 · Take the controls

```bash
demo/tools/kennel-demo.sh teleop
```

This starts the bridge between the browser and the running stack, and hands
the console its address.

**Success looks like:** it prints a `ws://` address and a Meshcat URL, a line
about the watchdog, and then tells you to go to *Dashboard → Interventions →
connect bridge*.

### 6 · Connect

In the console, open **Dashboard** and click **connect bridge** in the
Interventions panel.

```click
dashboard
connect
```

**Success looks like:** the Interventions line reads `driving`, the status bar
at the bottom says **mode · live**, and the panels stop showing their empty
states one by one as real data arrives.

### 7 · Choose a gait

In the gait picker beside the joystick, choose **WALKING_TROT**.

```click
gait WALKING_TROT
```

**Success looks like:** the picker reports `gait WALKING_TROT active` and the
period it read back from the robot. If it says *refused*, the robot did not
change gait — wait a second and pick it again.

### 8 · Drive

Push the joystick **straight up** and hold it for ten seconds, then let go.

```click
stick -1
hold 10
release
```

**Success looks like:** in Meshcat the robot trots away from where it started;
the status bar reads `driving · 20 Hz` for as long as you hold the stick; the
state plots show the actual velocity climbing to meet the commanded one (about
0.5 m/s, the **max v** field beside the stick); no block in the pipeline health
strip is red and no fall banner appears.

---

**The robot has walked 10 s under your command.**

That is the whole of the first run. Next: `walkthrough.md` takes the same five
minutes apart and explains what each piece was doing, and `diagnosis.md` is how
to read the Dashboard when a run goes wrong.

When you are done, `demo/tools/kennel-demo.sh teleop stop` returns the robot to
standing and closes the bridge, and `demo/tools/kennel-demo.sh down` stops the
stack.

---

### About the fenced blocks

Each step's action is in a fenced block so that this page can be *performed*
rather than only read: `demo/tools/kennel-demo.sh scenario firstwalk` runs this
file top to bottom, on a stopwatch, and asserts that every command it executed
came from this page. A `bash` block is a command you type; a `click` block is
something you do in the console, in this vocabulary:

| In a `click` block | What you do |
|---|---|
| `preset <name>` | open **load preset…** and pick that preset |
| `send` | click **send to kennel-runs →** |
| `dashboard` | open the **Dashboard** view |
| `connect` | click **connect bridge** |
| `gait <NAME>` | choose that gait in the picker |
| `stick -1` | push the joystick fully forward |
| `hold <n>` | keep it there for *n* seconds of simulated time |
| `release` | let the joystick go |
