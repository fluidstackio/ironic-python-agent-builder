# Qual-Agent Implementation Plan (living doc)

**Status:** source of truth for building out node qualification in the IPA
ramdisk ("qualOS"). Update this doc as PRs land — it is intentionally checked in
so the plan and the code evolve together.

| PR | Scope | Status |
|----|-------|--------|
| A | `qual-agent` element (binary from S3) + placeholder configs + this doc | 🟡 in progress |
| B | CA consumption contract + fold in the `qual_hold` clean-step gate | ⚪ not started |
| C | CI: fetch + fingerprint-pin the CA (and binary) from S3, add qual build variant | ⚪ not started |
| D | CA lifecycle: reproducible placeholder mint + expiry alerting | ⚪ not started |
| E | Docs: README + provisioning-workflow updates | ⚪ not started |

---

## Repo boundary (read this first)

**The `qual-agent` binary is NOT built in this repo.** It is produced by a
separate project and **pulled from S3** at build time via `DIB_QUAL_AGENT_FILE`.
This repo is the IPA *builder*: its only job is to **bake the agent binary,
its trust anchor (CA), its config, and the clean-step gate into the ramdisk** —
never to implement the agent's logic.

So responsibilities split cleanly:

| Concern | Owner |
|---|---|
| Enrollment / mTLS / qualification logic, cert *consumption* | the **agent binary** (separate repo → S3) |
| Placing the CA, config, binary, service, and gate into the image | **this repo** (`dib/qual-agent`) |
| The contract between them (paths, env vars, verdict file) | **this doc** |

Where "update the agent to look for the cert" (item 2) requires a change to the
binary itself, that change lives in the agent's repo; here we only guarantee the
files are present at the contracted locations and record the contract.

## Contract (agent ⇄ ramdisk)

The image guarantees, and the agent must rely on:

- `/usr/local/bin/qual-agent` — the binary (from S3, or a placeholder binary).
- `/etc/qual/tls/ca.crt` — the **public** root CA trust anchor (server-auth TLS).
- `/etc/qual/tls/tls.{crt,key}` — where the agent persists its enrolled client
  leaf/key at runtime (not baked).
- `/etc/qual/qual-agent.env` — `QUAL_ORCH_ADDR`, `QUAL_ENROLL_ADDR`.
- `qual-agent.service` — starts the agent on boot.
- `/run/qual/verdict` — the agent writes `passed` | `failed`; the `qual_hold`
  clean step reads it to release/hold the node. **This file is the one
  integration seam.**

## Trust model (why the CA, and only the CA)

The agent authenticates the orchestrator on the enrollment call using **only**
`/etc/qual/tls/ca.crt` as the trust anchor: it verifies (1) the server leaf
chains to that CA, (2) the server proves possession of the leaf's key (TLS), and
(3) the leaf's SAN matches `QUAL_ENROLL_ADDR`. The CA is a **public** cert —
confidentiality doesn't matter, **integrity does** (a swapped CA = trusting a
rogue orchestrator), which is why CI fingerprint-pins it (PR C). We bake the
**root** (rotates on the order of years → rare rebuilds), not an intermediate.
This was proven end-to-end in the sandbox — see "Proof already done" below.

---

## Sandbox test harness (used by every PR's test steps)

The VM sandbox (`ipa-dev/testing-ipa-with-vm-sandbox.md`) is an EC2 box running
metal3-dev-env: Ironic/BMO as docker containers + libvirt node VMs as fake bare
metal. Connection details live in `ipa-dev/sandbox-resources.env` (IP may drift).

Canonical inner loop (`BOX` = sandbox host, `KEY` = its ssh key):

```sh
# 1. push element changes to the builder's installed element dir on the box
rsync -az -e "ssh -i $KEY" dib/qual-agent/ \
  ubuntu@$BOX:~/.venv/ipa/share/ironic-python-agent-builder/dib/qual-agent/

# 2. build the qual ramdisk on the box (~/build-qual-test.sh sets
#    DIB_QUAL_CA_FILE, DIB_QUAL_AGENT_FILE, QUAL_ENROLL_ADDR and the elements)
ssh -i $KEY ubuntu@$BOX 'nohup ~/build-qual-test.sh > ~/build-qual-test.log 2>&1 &'

# 3. STATIC verify the bake without booting (fast)
ssh -i $KEY ubuntu@$BOX \
  'xz -dc --format=lzma /tmp/ipa-qual-test.initramfs | cpio -idm \
     etc/qual/tls/ca.crt usr/local/bin/qual-agent etc/qual/qual-agent.env'

# 4. inject (do NOT restart the ironic container)
ssh -i $KEY ubuntu@$BOX 'cp /tmp/ipa-qual-test.{kernel,initramfs} \
  /opt/metal3-dev-env/ironic/html/images/ironic-python-agent.{kernel,initramfs}'

# 5. boot a node into it → qual_hold clean-wait (indefinite, observable):
#    provision then deprovision (deprovision reliably triggers the clean cycle)
kubectl patch bmh -n metal3 node-0 --type=merge -p '{"spec":{"image":null}}'

# 6. verify from inside the ramdisk (node ip from ironic agent_url; debug key)
ssh -i /tmp/ipa-debug debug@<NODE_IP> 'sudo openssl x509 -in /etc/qual/tls/ca.crt -noout -fingerprint -sha256'

# 7. release: echo passed | sudo tee /run/qual/verdict   → node returns to available
```

### Proof already done (de-risks PR A/B)

A mock orchestrator (`qual-mock-orch.service`, TLS on `172.22.0.1:8443`, leaf
signed by a test CA with `SAN=IP:172.22.0.1,DNS:qual-orch.test`) plus the
sandbox-only `qual-enroll-test` element (a stand-in agent) demonstrated on a
booted node:

- baked `/etc/qual/tls/ca.crt` == source CA (SHA256 match), and
- **positive** verify VERIFIED; **negative** (rogue-CA server) and **negative**
  (wrong SAN) both REJECTED → the baked CA genuinely gates trust.

`qual-enroll-test` + the mock orchestrator remain **sandbox-only test tooling**;
they are never shipped in a production qual image.

---

## PR A — `qual-agent` element (binary from S3) + placeholder configs + this doc

**Goal:** a complete, reviewable `qual-agent` DIB element that bakes the
S3-delivered binary, its CA, config, and service into the ramdisk, with
placeholder config values. No agent logic (that's external). Commit this doc.

**Files**
- `dib/qual-agent/**` — the element (staged; carried fresh onto this branch).
- `dib/qual-agent/environment.d/10-qual-agent.bash` — placeholder `QUAL_ORCH_ADDR`
  / `QUAL_ENROLL_ADDR`; `DIB_QUAL_AGENT_FILE` / `DIB_QUAL_CA_FILE` (paths on the
  build host to the S3-fetched artifacts).
- `dib/qual-agent/install.d/40-qual-agent-binary` — installs the S3 binary;
  comment that the binary is **always** external (no in-repo fallback).
- `dib/qual-agent/README.rst` — link to this doc; state the repo boundary.
- `docs/qual-agent-implementation-plan.md` — this file.

**Testing steps**
1. On the box, ensure `DIB_QUAL_AGENT_FILE` points at a placeholder binary (the
   one already in `~/qual-artifacts/qual-agent`) and run the harness build.
2. STATIC verify (harness step 3): confirm `/usr/local/bin/qual-agent` present +
   `0755`, `/etc/qual/qual-agent.env` contains the placeholder addrs.
3. Boot a node (harness steps 4–6): `systemctl is-enabled qual-agent.service` →
   `enabled`; the unit attempts to start the binary.

**Acceptance:** element builds; binary + config + service baked; `is-enabled`
= enabled. No agent source in this repo. Doc committed.

**Depends on:** none.

---

## PR B — CA consumption contract + fold in the `qual_hold` clean-step gate

**Goal:** guarantee the CA + config land where the agent looks, and bring the
clean-step gate (the ramdisk-side half of qualification) into `qual-agent`.

**Files**
- `dib/qual-agent/install.d/50-qual-agent-ca` — bakes CA → `/etc/qual/tls/ca.crt`
  (already present; confirm mode/path against contract).
- Move `qual_hold_hardware_manager.py` + its `post-install.d` registration from
  the old `qual-hold-test` scaffold **into** `dib/qual-agent` (the HWM docstring
  already says it "folds into the qual-agent element when productionized").
- `dib/qual-agent/README.rst` — document the `/run/qual/verdict` contract.

**Testing steps**
1. Build + inject via the harness.
2. Deprovision a node → confirm it parks in `clean wait` on `qual_hold`
   (`baremetal node show … -c provision_state`).
3. On the ramdisk, confirm the CA fingerprint matches the source (harness 6),
   and re-run the sandbox proof (mock orchestrator + `tls-proof.py`):
   positive VERIFIED, rogue-CA + wrong-SAN REJECTED.
4. `echo passed | sudo tee /run/qual/verdict` → node advances to `available`;
   `echo failed …` on a fresh run → `clean failed`.

**Acceptance:** node holds on `qual_hold`; verdict contract drives release/hold;
CA-consumption proof passes.

**Depends on:** PR A.

---

## PR C — CI: fetch + fingerprint-pin CA (and binary) from S3, add qual variant

**Goal:** the release workflow pulls the CA + agent binary from S3, integrity-
pins the CA, and builds/publishes a qual ramdisk.

**Files**
- `.github/workflows/ipa-ramdisk-build.yml`:
  1. Move/duplicate the **Configure AWS credentials** step to *before* the build.
  2. **Fetch qual artifacts**: `aws s3 cp` CA + binary → `/tmp`; then
     `echo "$vars.QUAL_ROOT_CA_SHA256  /tmp/ca.pem" | sha256sum -c -` (pin).
  3. Add a **`qual` matrix entry** (decision below) setting `DIB_QUAL_CA_FILE` /
     `DIB_QUAL_AGENT_FILE` and `--element qual-agent`; publish to S3.

**Testing steps**
1. `workflow_dispatch` on this branch.
2. Tamper test: bump the object or the pin → the `sha256sum -c` step must fail.
3. On the published artifact, STATIC verify the CA is baked (harness step 3).

**Acceptance:** green build; pin gate works; qual image in S3 carries the CA.

**Decision:** dedicated **`qual`** matrix entry (isolation, recommended) vs. add
qual elements to **`gpu-noble`** (docs say qualification runs there). Start
dedicated; fold into gpu-noble once stable.

**Depends on:** PR A (element accepts the S3 binary). Parallel with PR B.

---

## PR D — CA lifecycle: reproducible mint + expiry alerting

**Goal:** close the last unreproducible link and add a rotation safety net.

**Files**
- `tools/gen-qual-placeholder-ca.sh` — deterministic `openssl` mint of the
  placeholder root CA (today it's an orphan file with no minting script).
- `.github/workflows/qual-ca-expiry-check.yml` — scheduled cron: `aws s3 cp` the
  pinned CA → `openssl x509 -checkend $((30*86400))` → open issue / notify.

**Testing steps**
1. Run the mint script locally; diff the subject/usage against the current
   placeholder.
2. Dry-run the expiry workflow with a tiny `-checkend` to force the alert path.

**Acceptance:** mint reproducible; expiry job notifies within threshold.

**Depends on:** none.

---

## PR E — Docs

Update `dib/qual-agent/README.rst` and `docs/provisioning-workflow.md` to
describe the shipped flow; reference the sandbox loop. Land last.

---

## Sequencing

```
PR A ──▶ PR B ──▶ PR E(docs)
   └────▶ PR C (parallel with B)
PR D  (independent, anytime)
```

Critical path **A → B**. C parallels B. D/E slot in around them. Every PR is a
fresh branch off `main`.
