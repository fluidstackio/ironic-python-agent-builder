# Agent Enrollment & Certificate Bootstrap — System Design

Status: **proposed** · supersedes the "certs baked in via ZTP" assumption in `RFC.md`
(§ Agent Authentication, § Cert Rotation).

This document describes how a qualification agent, booting inside a **shared, identity-less
ramdisk**, obtains a per-host mTLS client certificate at runtime and then talks to the
qual-orchestrator over mutual TLS. It spans two repos:

- **`ironic-python-agent-builder`** (this repo) — builds the ramdisk image and bakes in the agent
  binary + the trust anchor.
- **qual-orchestrator / qual-agent** (Go) — the `EnrollmentService`, the CA signer, the agent
  bootstrap logic, and the Crucible integration.

---

## 1. Goals and non-goals

**Goals**

- Every host obtains a **unique** mTLS client identity without baking per-host secrets into the
  (shared) ramdisk image.
- The bootstrap channel authenticates the **orchestrator** to the agent (no blind trust of
  material received over the wire).
- Issuance is **authorized against Crucible** (the asset system of record), not by self-asserted
  fields alone.
- Issued certs chain to the existing **Fluidstack Root CA**, so no trust-bundle changes are needed
  for the orchestrator mTLS endpoint or the OTLP gateway.
- The agent self-enrolls; the ramdisk build stays generic across the entire fleet.

**Non-goals**

- Cryptographic proof that the *caller* is the node it claims to be (TPM/attestation). We rely on
  network isolation for caller authenticity and document the residual risk (§6).
- Long-lived agent identity. Certs are short-lived and RAM-only; the deployed OS is out of scope.
- Replacing the orchestrator's existing mTLS RPCs (`Register` / `StreamAssignments` /
  `ReportResult`) — enrollment is a new step *before* them.

---

## 2. Why this is needed — the shared-ramdisk constraint

The ramdisk is a **single image PXE/virtual-media-booted by every host**. A per-host secret cannot
be baked at build time without producing one image per machine, which breaks the shared-image and
CI-matrix model. So the certificate problem splits in two:

| Piece | Scope | Delivery |
| --- | --- | --- |
| **Fluidstack Root CA** (trust anchor) | fleet-wide, identical for all hosts | **baked at build time** (`DIB_QUAL_CA_FILE`) |
| **Orchestrator address + config** | fleet-wide | **baked at build time** (env file) |
| **Agent binary** | fleet-wide | **baked at build time** (pulled from S3) |
| **Per-host client cert + key** | unique per machine | **obtained at boot via enrollment** — never baked |

The first three are the same for every host and are baked. The last is unique and is bootstrapped
at runtime. This document is about that last row.

---

## 3. End-to-end flow

```mermaid
sequenceDiagram
    autonumber
    participant A as qual-agent (ramdisk, no identity)
    participant O as orchestrator EnrollmentService
    participant C as Crucible (asset SoT)
    participant CA as Intermediate CA (in-process signer)

    Note over A: boot. No client cert on disk.<br/>Root CA + binary + config baked in.
    A->>A: generate keypair, build PKCS#10 CSR<br/>(private key never leaves the host)
    A->>A: collect hardware identity<br/>(serial, mac, hostname, product, device_count, gpu uuids)
    A->>O: Enroll(EnrollRequest) over **one-way TLS**<br/>(agent verifies server via **baked Root CA**;<br/>agent presents no client cert)
    O->>C: QueryNode(serial / mac / hostname)
    alt node unknown or hardware mismatch
        C-->>O: not found / mismatch
        O-->>A: PermissionDenied (refused)
    else node known and matches
        C-->>O: authoritative asset record
        O->>O: verify CSR self-signature (proof-of-possession)
        O->>CA: sign CSR with server-built template<br/>(subject/SAN from Crucible, EKU=clientAuth, short validity)
        CA-->>O: leaf certificate
        O->>O: record issuance on NodeQualification CRD<br/>(serial, issuedAt)
        O-->>A: EnrollResponse{ certificate, ca_chain }
    end
    A->>A: persist cert+key to /etc/qual/tls/
    A->>O: Register / StreamAssignments / ReportResult over **mTLS**<br/>(verifies orchestrator against baked Root CA)
```

Enrollment is a new step that runs **before** `Register`, on a **separate listener** with
different transport security (server-auth TLS, not mutual).

---

## 4. Certificate & PKI design

```
Fluidstack Root CA  (offline; key never on the orchestrator)
        │  signs
        ▼
Orchestrator Intermediate CA  (cert-manager Certificate isCA:true,
        │                       key mounted into the orchestrator as a Secret)
        │  signs (in-process)
        ▼
Per-host agent leaf cert  (short-lived, clientAuth, RAM-only)
```

- **Root CA** — the existing Fluidstack Root. Its key stays offline. Its cert is the **trust
  anchor baked into the ramdisk** (`DIB_QUAL_CA_FILE`) and is what the agent uses to verify *both*
  the enroll endpoint and the mTLS endpoint.
- **Intermediate CA** — minted by cert-manager (`Certificate` with `isCA: true`) off the Root,
  mounted into the orchestrator as a Secret. The orchestrator signs CSRs with this **in-process**
  (`crypto/x509.CreateCertificate`). Keeping the root offline limits blast radius to a rotatable
  intermediate.
- **Leaf certs** — server-controlled template:
  - Subject CN / SAN derived from the **authoritative Crucible record**, *not* from the CSR.
  - `ExtKeyUsage = clientAuth` only.
  - `KeyUsage = digitalSignature`.
  - Short validity (see §7) — the ramdisk is ephemeral, so renewal = reboot + re-enroll.
  - Public key + proof-of-possession taken from the CSR; everything else overridden.

**Signing mechanism: in-process CA signing** (vs. cert-manager `CertificateRequest` per request, or
the K8s CSR API). Rationale: enrollment is a synchronous boot-time call — the agent blocks on one
request and expects a cert back. In-process signing returns the cert in the same call with no async
CR round-trip, no extra RBAC, and no coupling of agent identity to the kube CA. The intermediate
key is the only sensitive material the orchestrator holds, and it is a rotatable intermediate, not
the root.

---

## 5. Wire security — one-way TLS, not plaintext

The enroll channel is **TLS with server authentication only**:

- The orchestrator presents a server cert that chains to the **Fluidstack Root**.
- The agent verifies that server cert against the **Root CA baked into the image** — so it knows it
  is talking to the real orchestrator before sending anything.
- The agent presents **no client cert** (it has none yet). That asymmetry is the only thing
  "missing" — it does **not** require dropping to plaintext.

Why not plaintext: over plaintext the agent would have to trust the `ca_chain` and server identity
*received over the wire*, so an on-segment MITM could impersonate the orchestrator wholesale (swap
the server cert and chain, then feed the agent bogus assignments). Because we already bake the Root
CA, the agent has an independent trust anchor and never needs to trust wire-delivered material.
This keeps network isolation as **defense-in-depth** rather than the sole guarantee of
server-authenticity.

Nothing sensitive transits the enroll channel regardless: the CSR and the issued cert are both
public, and the private key never leaves the host. TLS here buys **server authentication and
integrity**, which is the point.

---

## 6. Trust model and residual risk

Issuance is gated by controls layered outside the request payload, because a self-asserted
MAC/hostname is spoofable:

1. **Server-authenticated channel (§5)** — the agent is guaranteed to be talking to the real
   orchestrator (baked Root CA).
2. **Crucible authorization (the gate)** — the orchestrator signs only if the claimed node exists
   in Crucible *and* its reported hardware (product, device count, …) matches the expected record.
   Unknown or mismatched → refused (`PermissionDenied`).
3. **Network isolation** — the enroll listener is reachable only from the qual VLAN, never exposed
   externally (NetworkPolicy).
4. **Server-side cert constraints** — the orchestrator, not the client, sets subject/SAN, key
   usage, and validity. The CSR contributes only the public key and proof-of-possession.
5. **Bounded, recorded, short-lived issuance** (§7) — every issuance is recorded; certs expire
   quickly.

**Residual risk (stated plainly).** Crucible verifies that *an asset record exists and matches* —
it does **not** bind the CSR's key to the physical caller. An attacker already on the qual VLAN
could present a **known-good identity + their own CSR** and obtain a valid client cert impersonating
that node. Server-auth TLS (§5) does not close this — it authenticates the server, not the client.
**Caller authenticity therefore rests entirely on the network boundary (control 3).** If that
boundary is ever deemed insufficient, the next step is a bootstrap secret or hardware attestation
(TPM) bound into the enroll request — explicitly out of scope here, but the design leaves room for
an added authenticator field.

---

## 7. Issuance lifecycle, bounding, and rotation

The ramdisk is **ephemeral**: a host can legitimately reboot and re-run qualification, and each
boot starts with no cert. A hard "enroll once ever" rule would block legitimate re-qualification.

**Policy (recommended):**

- **Allow re-enroll freely**, but **record each issuance** on the `NodeQualification` CRD (cert
  serial + `issuedAt` + an `Enrolled` condition).
- Bound abuse with **short leaf validity** + the **Crucible gate on every call**, not with a hard
  issuance cap. A spoofer must keep passing Crucible and only ever holds short-lived certs.
- **CRD ownership moves to `Enroll`**: `Enroll` creates (or upserts) the `NodeQualification` CRD;
  `Register` then **binds to the existing CRD** instead of creating it.

**Rotation.** Short leaf validity + re-enroll-on-expiry replaces the RFC's MinIO
cert-publish/rotation webhook for agents. For RAM-only ephemeral agents the natural rotation event
is a reboot; for long-running qual sessions the agent re-enrolls as the cert nears expiry. The
validity window is an infra decision (§10).

---

## 8. Components

### 8.1 Ramdisk build (`ironic-python-agent-builder`, `dib/qual-agent/`)

The element bakes the three fleet-wide pieces and lets the **agent binary self-enroll** — there is
**no separate enrollment script**; the Go agent does gen-key → CSR → Enroll → persist → mTLS
internally on startup.

| File | Responsibility |
| --- | --- |
| `extra-data.d/15-qual-ca-copy` | stage the Root CA (`DIB_QUAL_CA_FILE`) on the build host |
| `extra-data.d/16-qual-agent-binary-copy` | stage the agent binary (`DIB_QUAL_AGENT_FILE`, pulled from S3 by CI) |
| `install.d/40-qual-agent-binary` | install `/usr/local/bin/qual-agent` |
| `install.d/50-qual-agent-ca` | install Root CA → `/etc/qual/tls/ca.pem` |
| `install.d/55-qual-agent-config` | write `/etc/qual/qual-agent.env` (orchestrator addr, enroll addr, cert paths) |
| `install.d/60-qual-agent-services` | enable `qual-agent.service` |
| `static/.../qual-agent.service` | runs the binary, which self-enrolls then proceeds to mTLS |

Build-time inputs (CI `env:` / repo vars & secrets):

- `DIB_QUAL_AGENT_FILE` — local path to the S3-pulled binary.
- `DIB_QUAL_CA_FILE` — local path to the Root CA (from secret `QUAL_ORCH_CA`).
- `QUAL_ENROLL_ADDR` — enroll endpoint (e.g. `orchestrator.qual.svc:9444`).
- `QUAL_ORCH_ADDR` — mTLS endpoint.

> **Change from the earlier scaffold:** the bash `qual-agent-enroll.sh` + `qual-agent-enroll.service`
> are removed. Enrollment is the binary's responsibility (PR 4), and cert paths standardize on
> `/etc/qual/tls/`.

### 8.2 Agent bootstrap (`internal/agent`)

On startup, if there is no usable client cert at `/etc/qual/tls/host.crt`:

1. `collectHardware()` (reused) — serial, mac, hostname, product, device count, gpu uuids.
2. Generate keypair; build a PKCS#10 CSR (CN is a hint; orchestrator overrides).
3. Dial `QUAL_ENROLL_ADDR` over **server-auth TLS**, verifying against `/etc/qual/tls/ca.pem`.
4. Call `Enroll`; persist `certificate` (+ key, + `ca_chain` if returned) to `/etc/qual/tls/`.
5. Fall through to the existing `dialMTLS` path, verifying the orchestrator against the **baked**
   Root CA.

### 8.3 Orchestrator `EnrollmentService` (`internal/orchestrator`)

- A second gRPC server (`ListenAndServePlaintext` → renamed to reflect server-auth TLS), registering
  only `EnrollmentService`, with the same context-logger interceptors as the mTLS server.
- `Enroll` handler: Crucible verify → CSR PoP verify → in-process sign → record issuance on the CRD.
- New flags: `--enroll-addr` (e.g. `:9444`), `--enroll-server-cert`, `--enroll-server-key`,
  `--enroll-ca-cert`, `--enroll-ca-key` (intermediate signing material).

### 8.4 CA signer (`internal/enrollment` or `internal/orchestrator/ca`)

Pure, dependency-light: load the intermediate CA cert+key from PEM, parse and **verify the CSR's
self-signature**, mint a leaf with a server-built template (subject/SAN/EKU/validity). Unit-tested
with a throwaway in-test CA.

### 8.5 Crucible verification (`internal/orchestrator/node_registry.go`)

Reuse the existing `NodeRegistry.QueryNode(ctx, ...)` abstraction (currently a stub). The enroll
handler queries Crucible, refuses unknown nodes, and validates hardware fields the same way
`Register` does today. Key the lookup on **board/chassis serial first**, MAC secondary (MAC is both
spoofable and unstable across NICs). No new external dependency — the real Crucible client lands
here when the stub is replaced.

---

## 9. API contract

A **separate service** (not another RPC on `QualificationService`) because it is served on a
different listener with different transport security.

```proto
service EnrollmentService {
  // Served over server-authenticated TLS (no client cert required).
  rpc Enroll(EnrollRequest) returns (EnrollResponse);
}

message EnrollRequest {
  // --- hardware identity (verified against Crucible) ---
  string board_serial         = 1;  // primary identity key → Crucible lookup
  string mac_address          = 2;  // secondary key
  string hostname             = 3;
  string accelerator_product  = 4;  // verified against Crucible record
  int32  device_count         = 5;  // verified against Crucible record
  repeated string gpu_uuids   = 6;  // optional additional attributes
  // --- key material ---
  bytes  csr                  = 7;  // PEM PKCS#10; supplies pubkey + proof-of-possession
}

message EnrollResponse {
  bytes certificate = 1;  // PEM leaf cert, signed by the intermediate CA
  bytes ca_chain    = 2;  // PEM intermediate (+root) to build the presented chain;
                          // NOT the trust source — the agent trusts the BAKED root
}
```

The orchestrator **ignores** subject/SAN/extensions in the CSR and builds its own template; only
the public key and the self-signature (proof the agent holds the private key) are trusted from it.

---

## 10. Deployment

- **cert-manager** `Certificate` with `isCA: true` for the orchestrator's intermediate CA, issued
  by the Fluidstack Root issuer, mounted into the orchestrator pod as a Secret.
- A **server cert** for the enroll + mTLS listeners, also chaining to the Root.
- A **Service/port** for the enroll endpoint (e.g. `:9444`).
- A **NetworkPolicy** restricting the enroll port to the qual VLAN (load-bearing — see §6 residual
  risk).
- Update `testing-agent-deployment.md` to **remove the manual cert `write_files`** step (the agent
  now self-enrolls).

Infra decisions to confirm: leaf **validity window**, and that cert-manager will mint the
**intermediate** (root stays offline).

---

## 11. Stacked PR plan

Each PR builds and tests green on its own; later PRs stack on earlier branches.

- **PR 1 — proto + generated code.** Add `proto/enrollment.proto`, run `buf generate`. No behavior
  change.
- **PR 2 — CA signer package.** Load intermediate CA, verify CSR self-signature, mint leaf with a
  server-controlled template. Unit tests with an in-test CA. No server wiring.
- **PR 3 — orchestrator enroll handler + listener.** Depends on PR 1 + 2. Server-auth-TLS gRPC
  listener registering only `EnrollmentService`; `Enroll` handler (Crucible verify → PoP verify →
  sign → record on CRD); `--enroll-*` flags; envtest coverage for verify/sign/re-enroll.
- **PR 4 — agent enrollment bootstrap.** Depends on PR 1. On startup, if no usable cert: collect
  hardware, gen key, build CSR, dial enroll over server-auth TLS (verify via baked Root), persist
  to `/etc/qual/tls/`, then fall through to mTLS.
- **PR 5 — ramdisk element + deployment + docs.** `dib/qual-agent/` bakes binary + Root CA +
  config and **drops the bash enroll script**; cert-manager intermediate `Certificate`; enroll
  Service + NetworkPolicy; docs cleanup.

---

## 12. Threat model summary

| Threat | Mitigation | Residual |
| --- | --- | --- |
| MITM impersonates orchestrator on enroll | server-auth TLS verified against **baked** Root CA (§5) | none material |
| On-VLAN attacker claims a known node + own CSR | network isolation + Crucible gate + short validity (§6) | **not fully closed** — needs bootstrap secret/attestation to eliminate |
| Stolen leaf private key | RAM-only + short validity; never written to durable storage | window-bounded |
| Compromised intermediate CA | rotate intermediate; root stays offline | blast radius = intermediate only |
| Self-asserted identity in cert | server builds template from Crucible, overrides CSR subject/SAN | none |
| Unbounded cert minting | recorded issuance + short validity + per-call Crucible gate (§7) | spoofer limited to short-lived certs while passing Crucible |

---

## 13. Summary

The agent boots with **no identity** but **with the Root CA, the binary, and config baked in**. It
self-enrolls over a **server-authenticated** channel, proving key possession via a CSR; the
orchestrator **authorizes against Crucible**, signs with an **in-process intermediate CA**, and
returns a **short-lived, server-templated** leaf cert. The ramdisk stays generic across the fleet,
no per-host secret is ever baked, and issued certs slot into the existing Fluidstack Root trust
chain with no bundle changes. The one acknowledged gap — caller authenticity on a trusted VLAN — is
documented and has a defined upgrade path (bootstrap secret / attestation).
