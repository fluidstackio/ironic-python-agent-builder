==========
qual-agent
==========
Installs the ``qual-agent`` qualification service into the ramdisk, together
with the bits it needs to talk to the qual-orchestrator over mutual TLS.

Trust model
-----------
The ramdisk is a **single image shared by every host** (PXE / virtual-media
booted). Therefore *no per-host secret can be baked in at build time* — that
would mean one image per machine. Instead the cert problem is split in two:

* **Fluidstack Root CA** — fleet-wide, identical for all hosts → **baked at
  build time** (this element) to ``/etc/qual/tls/ca.crt``. Lets qual-agent
  verify it is really talking to the orchestrator, at both enrollment and the
  subsequent mTLS calls.
* **Per-host client cert** — unique per machine → **obtained at boot time** via
  enrollment. Never touches the build.

Boot-time enrollment flow
-------------------------
Enrollment is performed by the ``qual-agent`` **binary itself** on startup —
there is no separate enrollment script or unit. If no usable client cert is
present under ``/etc/qual/tls/``, the agent:

1. Collects this host's hardware identity (MAC, hostname, accelerator product,
   device count).
2. Generates a keypair locally and builds a CSR — **the private key never
   leaves the host**.
3. Calls ``Enroll`` on the orchestrator's enroll endpoint
   (``QUAL_ENROLL_ADDR``) over **server-auth TLS**: it verifies the server
   against the baked Root CA and presents no client cert (it has none yet).
4. Persists the returned signed leaf to ``/etc/qual/tls/tls.crt`` (and key to
   ``tls.key``), then proceeds to the mTLS RPCs against ``QUAL_ORCH_ADDR``.

Because the ramdisk is ephemeral, the cert lives only in RAM for the
qualification session — the orchestrator issues short-lived certs.

Build-time variables
---------------------
* ``QUAL_ORCH_ADDR`` — orchestrator mTLS endpoint as ``host:port``, baked into
  the runtime env file and passed to the agent as ``--orchestrator``.
  Fleet-wide. Defaults to ``qual-orchestrator.example.com:9443``.
* ``QUAL_ENROLL_ADDR`` — enrollment endpoint as ``host:port``, passed as
  ``--enroll-addr``. Fleet-wide. Defaults to
  ``qual-orchestrator.example.com:9444``.
* ``DIB_QUAL_CA_FILE`` — path on the build host to the Fluidstack Root CA (PEM).
  Baked to ``/etc/qual/tls/ca.crt`` so qual-agent trusts the orchestrator. If
  unset, no CA is baked and TLS verification of the server will fail.
* ``DIB_QUAL_AGENT_FILE`` — path on the build host to the qual-agent binary.
  The CI job pulls it from S3
  (``s3://fish-artifacts-.../fluidstack/node-qualification/qual-agent-<TAG>``)
  before the build and points this at the local copy. If unset, the binary is
  **not** installed.
* ``DIB_QUAL_AGENT_VERSION`` — informational version tag. Defaults to ``1.4.0``.
