# Qual-agent end-to-end validation plan (VM sandbox)

A phased plan to validate the **full node-qualification flow** — from a host
booting the shared IPA ramdisk, through certificate enrollment, to the
orchestrator driving qualification to a terminal state — entirely in the
libvirt/metal3 **VM sandbox** (no hardware, no prod). Each phase has an
explicit **exit criterion**; later phases depend on earlier ones.

Companion docs:
- [`testing-ipa-with-vm-sandbox.md`](testing-ipa-with-vm-sandbox.md) — standing up the sandbox.
- [`qual-agent-sandbox-walkthrough.md`](qual-agent-sandbox-walkthrough.md) — building/booting the qual-agent IPA (Phase 2, already proven).
- [`../docs/agent-enrollment-design.md`](../docs/agent-enrollment-design.md) — the enrollment/PKI system design.

## Architecture under test

**Decision (confirmed):** in production the qual-agent runs **inside the IPA
ramdisk** (not the deployed OS), and the node is **held in the ramdisk by a
blocking Ironic clean step** for the duration of qualification.

```
node boots shared IPA ramdisk  (no identity; Root CA + agent + addrs baked)
   └─ qual-agent.service self-enrolls → Enroll RPC (server-auth TLS) → leaf cert in /etc/qual/tls/
        └─ Ironic runs cleaning → [qual_gate clean step] → node sits in `clean wait`
              (booted in IPA, heartbeating; Ironic will not deploy over it)
                 └─ orchestrator drives qualification over mTLS (Register / StreamAssignments / ReportResult)
                       └─ orchestrator reaches a terminal state on the NodeQualification CRD:
                            Qualified            → qual_gate returns success → cleaning completes
                            FailedPendingReview  → qual_gate raises           → `clean failed` (node HELD for triage)
```

The **`qual_gate` clean step** (a custom IPA `HardwareManager`, not yet built)
is the connective tissue: it gives Ironic a reason to keep the node in the
ramdisk and turns the orchestrator's terminal verdict into Ironic pass/fail.
It is a thin **gate** — it does not run tests; the systemd agent + orchestrator
own that. Build pattern mirrors `dib/fluidstack-ironwood`'s HardwareManager
(entry-point registered via `post-install.d`).

## Sandbox specifics that shape the plan

| Fact | Implication |
|---|---|
| `USE_IRSO=false` → Ironic runs as **Docker containers** | drive Ironic via its **HTTPS+noauth API** (`curl -sk https://localhost:6385 -H 'X-Auth-Token: noauth'`); no `baremetal` CLI in the container. |
| metal3 BMH only exposes `automatedCleaningMode: metadata\|disabled` | **no arbitrary clean steps via the CRD** → manual cleaning with a custom step is driven **through Ironic directly**, bypassing BMO. |
| `[conductor]clean_callback_timeout` **unset → default 1800 s (30 min)** | the key clean-wait knob; see Phase 1. (`deploy_callback_timeout=4800`, `[deploy]fast_track=true` are set.) |
| Nodes are GPU-less libvirt VMs | `nvidia-smi`-based hardware collection fails; must be stubbed before enrollment (Phase 3). |
| Ramdisk is RAM-only | a 48 h soak pins the rootfs in RAM the whole time and a reboot loses state (Phase 6 risk). |

---

## Phase 1 — clean-wait hold & timeout management

**Goal.** Prove we can park a node in `clean wait` **indefinitely** and that
the governing timeout is understood and tunable. This de-risks everything
downstream: if we can't hold the node, we can't run qual in the ramdisk.

**Mechanism.** A clean step runs in a worker thread while the agent keeps
**heartbeating**; Ironic resets `clean_callback_timeout` on each heartbeat, so a
long step does not trip it. We validate this with a minimal **`hold` clean
step** that blocks on a sentinel (a file under `/var/run/qual/`), released
manually.

**Steps.**
1. Add a throwaway `HardwareManager` with a single async clean step that loops
   until `/var/run/qual/release` exists (sleep+heartbeat). Bake it into the IPA
   (its own element or folded into `dib/qual-agent`), rebuild, inject.
2. From the box, move `node-0` to `manageable`, then start **manual cleaning**
   with that step via the Ironic API.
3. Watch `provision_state` go `clean wait` and **stay** there; SSH into the
   ramdisk and confirm the step thread is alive and heartbeats continue.
4. Let wall-clock exceed `clean_callback_timeout` (30 min) **without** dropping
   the sentinel → confirm the node does **not** go `clean failed` (heartbeats
   reset the timer). Then drop the sentinel → step returns → cleaning completes.
5. Separately, force a timeout: pause heartbeats (or set a tiny
   `clean_callback_timeout`) → confirm Ironic moves the node to `clean failed`
   after the window. This proves the knob is the thing that governs the hold.

**Exit criterion.** A node holds in `clean wait` well past 30 min with
heartbeats flowing; we can articulate exactly which config (`clean_callback_timeout`,
plus async-step + heartbeat behaviour, `fast_track`) bounds a long hold and how
to raise it for a 48 h soak. **✅ MET** — see Status/results below (~17.5 h hold).

**Risks.** Per-step vs. callback timeouts conflated; a blocking (non-async)
step starving the heartbeat thread → use an async command.

**Status: PROVEN.** A node held in `clean wait` for **~17.5 h continuously**
(63,180 s) — vastly past the 1800 s `clean_callback_timeout` — heartbeats flowing,
no `clean failed`. The 48 h-soak hold is viable on this mechanism.

**Auto-entry + external-signal release — DEMONSTRATED (production shape).** No
operator API calls / no per-node step injection:
- The gate step is baked at **`priority > 0`** (currently 100), so it runs during
  Ironic **automated cleaning**, which the metal3 lifecycle triggers on its own.
- **metal3-native run CONFIRMED (BMO up, no manual Ironic calls).** Provisioning a
  BMH (`spec.image`) goes `available → provisioning → provisioned` with **no**
  cleaning — metal3 does *not* clean on the way *into* provisioning. **Cleaning
  (and therefore our gate) fires on the path back to `available`: deprovision.**
  Deprovisioning (`remove /spec/image`) drove `provisioned → deprovisioning`, and
  Ironic `deleting → cleaning → clean wait` running **`qual_hold`** — the baked
  priority-100 step auto-ran under BMO with **no `--clean-steps`**. Writing
  `/run/qual/verdict=passed` then took it `cleaning → available` (BMH `available`).
- **`automatedCleaningMode: metadata` does NOT strip the custom step** — the gate
  ran under it. (`disabled` would skip cleaning entirely → gate would not run.)
- **While holding, the BMH shows `deprovisioning`** (metal3 view) while Ironic is
  `clean wait` + `clean_step=qual_hold`. (Earlier `node provide` with BMO=0 also
  worked but was the sandbox crutch; the deprovision path above is the real one.)
- **Lifecycle placement caveat:** metal3 cleans on transitions *to* `available`
  (deprovision/recycle, and a fresh node's first enrollment clean) — not before
  initial provisioning. So qual-via-clean-step gates the "(re)turn to available"
  events. Whether a brand-new BMH gets an initial automated clean (firing the gate
  at first enrollment, before it is ever `available`) still needs a direct test —
  our nodes were cleaned to `available` during `make`, before the gate existed.
- Release is an **external signal relayed through the qual-agent**, not a manual
  sentinel: the agent writes `/run/qual/verdict` when the orchestrator reaches a
  terminal state. `passed` → step returns → cleaning continues → node `available`;
  anything else → `CleaningError` → `clean failed` → node held in qualOS for triage
  (≈ `FailedPendingReview`). Verified the full `provide → auto-hold → verdict=passed
  → available` cycle.
- Seam for Phase 4/5: orchestrator --(gRPC terminal)--> qual-agent --(writes
  `/run/qual/verdict`)--> gate. Prototype lives in `dib/qual-hold-test`
  (`QualHoldHardwareManager`); folds into the `qual-agent` element when productionized.

**Execution mechanics (sandbox).**
- The hold step ships in a throwaway element, `dib/qual-hold-test` — a
  `QualHoldHardwareManager(GenericHardwareManager)` that adds a **`qual_hold`**
  clean step blocking on `/run/qual-hold-release`, registered via `post-install.d`
  exactly like `dib/fluidstack-ironwood`. Bake it alongside `qual-agent`.
- **Drive Ironic directly** (metal3 can't request custom clean steps). Remove BMO
  from the loop entirely: `kubectl -n baremetal-operator-system scale deploy
  baremetal-operator-controller-manager --replicas=0`. (`metal3 available` ⇒
  Ironic `manageable`, the launch state for manual cleaning.)
- Use **python-ironicclient**. Auth is HTTP basic; the **plaintext** creds are in
  `/opt/metal3-dev-env/ironic/auth/ironic-username|ironic-password` on the host
  (the k8s `ironic-credentials` secret's password did **not** match the htpasswd
  here — use the host files). Endpoint `https://172.22.0.2:6385`, `--insecure`,
  `OS_AUTH_TYPE=http_basic`. Then: `baremetal node power off <uuid>` (fresh boot,
  no stale `fast_track` agent / no leftover sentinel) → `baremetal node clean
  <uuid> --clean-steps '[{"interface":"deploy","step":"qual_hold"}]'`.
- Release: `touch /run/qual-hold-release` on the ramdisk → step returns → cleaning
  completes → node back to `manageable`. (Verified the full hold→release cycle.)

**ROOT-CAUSE FINDING (the run-1 "empty steps" bug).** Ironic **reserves the step
names `power_on`, `power_off`, `reboot`, `hold`, `wait`** as internal
flow-control directives. In `ironic/conductor/steps.py:_validate_user_steps`, a
user step with one of those names is silently `continue`d (skipped), so it never
lands in the executable list and the stored `clean_steps` get overwritten to
`[]` → cleaning completes in seconds, no error. Our step was literally named
`hold`. **Renaming `hold` → `qual_hold` fixed it.** → **The production
`qual_gate` step must avoid those five reserved names.** (Ironic *does* have a
native `hold` flow-step; whether it's a cleaner production primitive than a
custom HW-manager step is a follow-up to explore.)

**How to VERIFY a hold (which surface shows what).**
- **Ironic = source of truth:** `baremetal node show <uuid> -f value -c
  provision_state -c clean_step` → `clean wait` + `clean_step.step = qual_hold`;
  `target_provision_state = manageable`, `last_error = None`.
- **BMH is NOT a reliable indicator here** — with BMO scaled to 0 the CR is frozen
  and shows a stale `available`. (Under normal metal3-driven cleaning the BMH
  would show `cleaning`, but that path can't carry custom steps.)
- **Agent (ramdisk):** `journalctl | grep qual-hold` → `still holding (Ns
  elapsed)` incrementing; `/run/qual-hold-release` absent.
- **VM:** `virsh domstate node_0` → `running`. **Liveness:** conductor logs
  periodic `Heartbeat from node … in state clean wait` (each resets the timer).

---

## Phase 2 — qual-agent baked into the ramdisk *(done)*

**Goal.** The custom IPA contains the agent, the Root CA, the env config, and
an enabled `qual-agent.service`, and boots on a node.

**Status.** ✅ Proven — see `qual-agent-sandbox-walkthrough.md`. Binary at
`/usr/local/bin/qual-agent` (sha256 matches build), CA at `/etc/qual/tls/ca.crt`,
env at `/etc/qual/qual-agent.env`, service `enabled` + `active`.

**Exit criterion.** Re-runnable from the walkthrough; sha256 of baked binary/CA
matches the build host.

---

## Phase 3 — enrollment with the orchestrator

**Goal.** A freshly booted, identity-less agent obtains a real mTLS client cert
via the `Enroll` RPC and then completes `Register` over mTLS.

**Prerequisites.**
- **Resolve hardware collection on a GPU-less VM** (the current blocker): the
  agent calls `nvidia-smi` *before* enrolling. Options: ship a fake `nvidia-smi`
  in the image (test element), pass a GPU through, or add an agent dev/skip path.
  Decide and implement first.
- **Orchestrator reachable from the node** (172.22.0.0/24). Run the
  orchestrator (from `systems`) somewhere on/behind the box — container on the
  provisioning net, or port-forwarded — listening on the mTLS (`:9443`) and
  enroll (`:9444`) ports.
- **Real PKI**: a Root CA + an intermediate the orchestrator signs with; bake
  the **matching** Root CA into the image (replace the placeholder) and point
  `QUAL_ENROLL_ADDR` / `QUAL_ORCH_ADDR` at the orchestrator.

**Steps.** Boot the node → watch the agent journal: hardware collected → CSR
generated → `Enroll` succeeds → leaf+key persisted to `/etc/qual/tls/tls.crt|key`
→ agent proceeds to dial mTLS and `Register`.

**Exit criterion.** `/etc/qual/tls/tls.crt` exists, chains to the baked Root CA,
has `ExtKeyUsage=clientAuth` and a short validity; the agent's `Register` over
mTLS is accepted by the orchestrator. Negative: an unknown MAC / hardware
mismatch is refused (`PermissionDenied`).

**Risks.** SAN/hostname verification vs. `--skip-hostname-verify`; clock skew vs.
short validity; CA-chain ordering in the persisted cert.

---

## Phase 4 — orchestrator terminal states ↔ clean-step gate

**Goal.** Drive the orchestrator/CRD to each terminal state and confirm the
agent and the `qual_gate` clean step react correctly.

**Steps.** With a node enrolled and held in `clean wait` (Phase 1 + 3), drive
the `NodeQualification` CRD (or stub the orchestrator's verdict) to:
- `Qualified` → `qual_gate` returns success → cleaning completes → node leaves IPA.
- `FailedPendingReview` (single-node failure) → `qual_gate` raises → `clean failed`,
  node **held** in IPA for triage.
- `SuspectPendingReview` → treated as the fail/triage path.

**Exit criterion.** Each orchestrator terminal state maps deterministically to
the right Ironic outcome and node power/boot state; the mapping is documented.

**Risks.** Race between the agent writing its result sentinel and the gate
polling; gate must tolerate agent reconnect after a mid-run reboot (state lives
in the CRD, not the node).

---

## Phase 5 — full test orchestration

**Goal.** End-to-end workload assignment and reporting, not just terminal
states: orchestrator assigns workloads (`StreamAssignments`), the agent runs the
qualification **shell scripts** locally, and reports results (`ReportResult`).

**Steps.** Register a product/workload set in the orchestrator config; boot the
node; confirm the agent receives assignments, executes the scripts (use trivial
pass/fail stand-ins for GPU/fabric tests in the VM), streams results, and the
orchestrator advances the CRD (`Qualifying → …`). Exercise both a passing run
and an injected failing threshold.

**Exit criterion.** A full single-node run drives the CRD from `Pending` to a
terminal state purely via the gRPC RPCs, with per-workload results recorded.

**Risks.** VMs can't run real NCCL/IB tests — use mock scripts; cohort/cluster
tiers need ≥2 nodes (the sandbox has `node-0`/`node-1`).

---

## Phase 6 — full soak

**Goal.** Validate the **endurance** path: a long (scaled-down proxy for 48 h)
soak while the node is held in `clean wait`, including heartbeat/timeout
behaviour over a long hold and reboot/re-enroll resilience.

**Steps.** Run a long soak workload; confirm the node holds in `clean wait` for
the full duration with no spurious `clean failed`; reboot the node mid-soak and
confirm it re-PXEs, **re-enrolls** (fresh short-lived cert), and the orchestrator
resumes from CRD state; verify final `Qualified`.

**Exit criterion.** A multi-hour soak completes without a timeout-induced drop;
a mid-soak reboot recovers via re-enrollment; final terminal state is correct.

**Risks (the headline ones for the ramdisk model).**
- **RAM-only rootfs** pinned for the whole soak — memory pressure, no disk use.
- **Reboot = lose all on-node state** → relies entirely on orchestrator/CRD
  state and re-enrollment; the most failure-prone seam — test it explicitly.
- Confirm whether a true 48 h soak is intended in-ramdisk at all, or handed off.

---

## Cross-cutting

- **Observability.** Agent logs via `journalctl -u qual-agent.service`; Ironic
  state via the API / `kubectl get bmh`; orchestrator via the CRD + its logs.
- **Teardown / reset.** Restore upstream IPA from the `.orig` symlinks; re-trigger
  inspection for a clean reboot; `make clean` to tear the sandbox down.
- **What this sandbox cannot prove.** Real GPU/fabric test results, true 48 h
  endurance, and real-BMC power/boot semantics (the blank-disk "available+online"
  hold does **not** generalise to a host with an OS on disk).
