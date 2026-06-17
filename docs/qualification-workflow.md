# Qualification workflow

How GPU node qualification integrates with Ironic and Metal3.

## Architecture

Qualification runs **inside the IPA ramdisk** during Ironic's cleaning phase.
The ramdisk is the single image every host boots via PXE or virtual media — no
per-host secrets or binaries are baked in at build time beyond fleet-wide
artifacts (the agent binary, the Root CA, and orchestrator addresses).

The flow is fully automated: a node entering cleaning runs the qualification
clean step, which blocks until the orchestrator issues a terminal verdict. No
manual API call is needed to trigger qualification.

```
BMH created ──► Ironic registers node
                        │
                        ▼
                   inspecting
                        │
                        ▼
                   manageable
                        │
                        ▼
                ┌── cleaning ──────────────────────────────────────┐
                │                                                   │
                │  IPA ramdisk boots                                │
                │       │                                           │
                │       ▼                                           │
                │  QualificationHardwareManager discovered          │
                │       │                                           │
                │       ▼                                           │
                │  qualify_node clean step starts                   │
                │       │                                           │
                │       ▼                                           │
                │  qual-agent --run-once                            │
                │       │                                           │
                │       ├─ self-enrolls (mTLS cert bootstrap)       │
                │       ├─ registers with orchestrator              │
                │       ├─ streams commands (single-node tests)     │
                │       ├─ orchestrator runs cohort / cluster tests │
                │       ├─ orchestrator runs multi-hour soak        │
                │       ├─ calls GetVerdict                         │
                │       │                                           │
                │       ▼                                           │
                │  exit 0 (PASSED) ──or── exit non-zero (FAILED)   │
                │       │                         │                 │
                └───────┼─────────────────────────┼─────────────────┘
                        │                         │
                        ▼                         ▼
                   available               clean failed
                        │               (node held for review)
                        ▼
                   provisioning
                        │
                        ▼
                     active
```

## Key components

### QualificationHardwareManager (this repo)

A custom IPA hardware manager registered as a DIB element (`dib/qual-agent`).
Exposes the `qualify_node` clean step at priority > 0, meaning it runs during
**automated cleaning** — no manual trigger needed.

The clean step execs `qual-agent --run-once` and waits for it to exit. The exit
code determines the Ironic outcome:

| Exit code | Meaning | Ironic result |
|-----------|---------|---------------|
| 0 | Qualification passed | Clean step succeeds → node becomes `available` |
| non-zero | Qualification failed | Clean step raises → node goes to `clean failed` |

### qual-agent (systems repo)

The qualification agent binary, baked into the ramdisk at
`/usr/local/bin/qual-agent`. In `--run-once` mode it:

1. **Self-enrolls**: generates an ECDSA keypair, sends a CSR to the
   orchestrator's `EnrollmentService` over server-auth TLS, receives a signed
   leaf certificate. The Root CA is baked into the ramdisk at
   `/etc/qual/tls/ca.crt`.

2. **Registers**: opens an mTLS gRPC stream to the orchestrator's
   `QualificationService`, which creates/updates a `NodeQualification` CRD.

3. **Runs qualification**: receives and executes test commands streamed by the
   orchestrator (hardware checks, stress tests, cohort/cluster coordination,
   soak monitoring).

4. **Exits with a verdict**: on stream end, calls `GetVerdict` to read the
   terminal phase from the CRD. `Qualified` → exit 0, any `Failed*` phase →
   exit non-zero.

### Orchestrator (systems repo)

The server-side component running in the qualification cluster. Manages
`NodeQualification` CRDs, drives the test pipeline, coordinates multi-node
cohort/cluster tests, and issues terminal verdicts.

## BMH configuration

For qualification to run automatically, the BareMetalHost must have automated
cleaning enabled:

```yaml
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: <node>
spec:
  automatedCleaningMode: metadata   # enables automated cleaning
  # ... other spec fields
```

With `automatedCleaningMode: disabled` (the default in some deployments),
cleaning is skipped entirely and the node goes straight to `available` without
qualification.

## Timeouts

Ironic's `[conductor] clean_callback_timeout` (default 1800 s) is a **heartbeat
liveness timeout**, not an absolute step-duration cap. The IPA agent heartbeats
to the conductor every ~60 s while running clean steps; each heartbeat resets
the timer. A qualification run lasting hours is safe as long as heartbeats
continue.

If the agent crashes or loses network connectivity, the timeout fires and the
node transitions to `clean failed` — which is the desired behavior (a dead
agent should not hold a node in cleaning forever).

The default 1800 s is a reasonable liveness window. It does NOT need to be raised
to match the total qualification duration.

> **Stage 0 verification**: the `sleep_test` step proves this heartbeat behavior
> empirically. See [qual-clean-timer-verification.md](qual-clean-timer-verification.md).

## Re-qualification after repair

When a node needs re-qualification (e.g. after a DIMM replacement), the
orchestrator's `OpsService.Qualify` endpoint resets the `NodeQualification` CRD.
On the next cleaning cycle (triggered by unprovisioning + reprovisioning the
node, or by moving it through `manageable` → cleaning), the agent re-runs the
full pipeline.

## Stages

| Stage | What ships | Purpose |
|-------|-----------|---------|
| 0 (this PR) | `sleep_test` clean step | Verify CLEANWAIT heartbeat behavior |
| 1 | Binary + Root CA + config baked into ramdisk | IPA can run the real agent |
| 2 | `qualify_node` clean step (replaces `sleep_test`) | Full qualification pipeline |
| 3 | Docs, cleanup, `evaluate_hardware_support` tightened to GPU | Production-ready |
