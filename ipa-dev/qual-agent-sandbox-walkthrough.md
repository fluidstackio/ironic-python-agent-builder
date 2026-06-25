# Baking & deploying the qual-agent IPA in the VM sandbox

A concrete, reproducible walkthrough of what it takes to get the **qual-agent
baked into a custom IPA ramdisk and booted on a metal3-dev-env node** — the
build-host steps, the inject, the boot, and the verification. This is the
qual-agent-specific companion to the generic harness in
[`testing-ipa-with-vm-sandbox.md`](testing-ipa-with-vm-sandbox.md); read that
first for how the sandbox itself is stood up.

> Everything below runs against an **already-up sandbox** (Linux+KVM box with
> `metal3-dev-env` built and `node-0`/`node-1` in `available`). The box's
> connection details are recorded in `ipa-dev/sandbox-resources.env`
> (`PUBLIC_IP`, `KEY_FILE`, …). Export them first:
>
> ```sh
> set -a; . ipa-dev/sandbox-resources.env; set +a
> KEY="${KEY_FILE/#\~/$HOME}"        # e.g. ~/.ssh/sys-eng-key-pair-abbas.pem
> BOX="ubuntu@${PUBLIC_IP}"
> ```

The pieces the qual-agent element (`dib/qual-agent`) needs at **build time**
(see its `README.rst`): the **agent binary**, the **Root CA** to bake, and the
fleet-wide **orchestrator/enroll addresses**. The per-host client cert is *not*
baked — the agent self-enrolls at boot.

| Build input | Var | Where it comes from |
|---|---|---|
| qual-agent binary | `DIB_QUAL_AGENT_FILE` | built from `systems` repo (`cmd/agent`) |
| Root CA (PEM) | `DIB_QUAL_CA_FILE` | prod: S3 artifacts bucket; sandbox: self-signed placeholder |
| orchestrator addr | `QUAL_ORCH_ADDR` | element default (`…example.com:9443`) or override |
| enroll addr | `QUAL_ENROLL_ADDR` | element default (`…example.com:9444`) or override |

---

## Step 1 — build the qual-agent binary (on your laptop)

The agent is a self-contained **static** binary (embeds its qualification
scripts/config), built `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` — `amd64`
matches the sandbox's `c5.metal`. Build the branch you want to test; the
self-enrolling agent lives on `enroll-04-agent`.

```sh
# in the systems repo (use a worktree so you don't disturb your checkout)
git -C ~/dev/systems worktree add /tmp/wt-enroll04 enroll-04-agent
cd /tmp/wt-enroll04
SHA=$(git rev-parse --short HEAD)
mkdir -p /tmp/qual-artifacts
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags "-X main.Version=$SHA" \
  -o /tmp/qual-artifacts/qual-agent ./projects/node-qualification/cmd/agent
file /tmp/qual-artifacts/qual-agent   # → ELF 64-bit x86-64, statically linked
```

## Step 2 — a Root CA to bake

The element bakes a CA to `/etc/qual/tls/ca.crt` so the agent can verify the
orchestrator at enrollment. In production this is the real Fluidstack Root CA
pulled from S3. For a **bake/boot smoke test** a self-signed placeholder is
fine (enrollment against a real orchestrator needs the *real* CA — see the
validation plan):

```sh
cd /tmp/qual-artifacts
openssl ecparam -name prime256v1 -genkey -noout -out qual-orch-root-ca.key
openssl req -x509 -new -key qual-orch-root-ca.key -sha256 -days 3650 \
  -subj "/O=Fluidstack/CN=Fluidstack Qual Root CA (dib-test placeholder)" \
  -out qual-orch-root-ca.pem
```

## Step 3 — get the `dib/qual-agent` element into your working tree

The element currently lives on the `enroll-ramdisk-self-enroll` branch. Bring
it into whatever branch you build from (it's just files; no need to commit):

```sh
cd ~/dev/ironic-python-agent-builder
git checkout enroll-ramdisk-self-enroll -- dib/qual-agent
find dib/qual-agent -type f          # element-deps, environment.d, extra-data.d, install.d, static/
# the install.d / extra-data.d hooks must be executable (755) — they are after checkout
```

## Step 4 — push repo + artifacts to the box, install the builder

```sh
ssh -i "$KEY" "$BOX" 'mkdir -p ~/qual-artifacts'
# repo: working tree incl. the uncommitted qual-agent element (exclude .git / ipa-dev for speed)
rsync -az --delete --exclude '.git' --exclude 'ipa-dev' -e "ssh -i $KEY" \
  ~/dev/ironic-python-agent-builder/ "$BOX":~/ironic-python-agent-builder/
rsync -az -e "ssh -i $KEY" \
  /tmp/qual-artifacts/qual-agent /tmp/qual-artifacts/qual-orch-root-ca.pem \
  "$BOX":~/qual-artifacts/

ssh -i "$KEY" "$BOX" 'cd ~/ironic-python-agent-builder && \
  python3 -m venv ~/.venv/ipa && . ~/.venv/ipa/bin/activate && \
  PBR_VERSION=0.0.1 pip install -q .'
```

> The builder finds custom elements by checking `./dib/` in the **cwd** first
> (`find_elements_path()`), so always run it from `~/ironic-python-agent-builder`
> — then `--element qual-agent` resolves with no `--elements-path`.

## Step 5 — build the custom IPA (on the box)

DIB needs Linux; this runs on the box, not your laptop. The build takes
~6–8 min; run it detached and tail the log.

```sh
ssh -i "$KEY" "$BOX" 'bash -s' <<'REMOTE'
set -e
# debug key so we can SSH into the running ramdisk
[ -f /tmp/ipa-debug ] || ssh-keygen -t ed25519 -f /tmp/ipa-debug -N '' -C ipa-debug

cat > ~/build-qual-ipa.sh <<'BUILD'
#!/bin/bash
set -eux
cd "$HOME/ironic-python-agent-builder"; . "$HOME/.venv/ipa/bin/activate"
export DIB_DEV_USER_USERNAME=debug
export DIB_DEV_USER_AUTHORIZED_KEYS=/tmp/ipa-debug.pub
export DIB_DEV_USER_PWDLESS_SUDO=yes
export DIB_QUAL_AGENT_FILE="$HOME/qual-artifacts/qual-agent"
export DIB_QUAL_CA_FILE="$HOME/qual-artifacts/qual-orch-root-ca.pem"
# QUAL_ORCH_ADDR / QUAL_ENROLL_ADDR left at element defaults (placeholders) for a smoke test;
# point them at a reachable orchestrator for the enrollment phase.
ironic-python-agent-builder --lzma --output /tmp/ipa-qual \
  --release 9-stream --branch master \
  --element qual-agent --element devuser --verbose centos
echo "BUILD_DONE rc=$?"
BUILD
chmod +x ~/build-qual-ipa.sh
nohup ~/build-qual-ipa.sh > ~/build-qual-ipa.log 2>&1 &
echo "launched pid $!"
REMOTE

# poll until BUILD_DONE (re-run as needed)
ssh -i "$KEY" "$BOX" 'tail -n3 ~/build-qual-ipa.log; ls -la /tmp/ipa-qual.kernel /tmp/ipa-qual.initramfs 2>/dev/null'
```

**Proof the agent was installed into the image** lives in `~/build-qual-ipa.log`:

```sh
ssh -i "$KEY" "$BOX" 'grep -nE "install.d/[0-9]+-qual-agent|/usr/local/bin/qual-agent|/etc/qual/tls/ca.crt|systemctl enable qual-agent" ~/build-qual-ipa.log'
# expect: install -m0755 …/qual-agent ; install -m0644 …/ca.crt ; Created symlink … qual-agent.service
```

The element list baked into the image is recorded in
`/tmp/ipa-qual.d/dib-manifests/dib_arguments` (look for `qual-agent`).

## Step 6 — inject into the sandbox's Ironic

`USE_IRSO=false` → Ironic runs as **Docker containers**; the served images are
host files (symlinks into the upstream tarball). Replace them with your build.
**Don't restart the `ironic` container** (it re-downloads and clobbers).

```sh
ssh -i "$KEY" "$BOX" 'bash -s' <<'REMOTE'
set -e
cd /opt/metal3-dev-env/ironic/html/images
# back up the upstream symlinks ONCE (don't clobber a prior .orig with your build)
[ -e ironic-python-agent.kernel.orig ]    || mv ironic-python-agent.kernel    ironic-python-agent.kernel.orig
[ -e ironic-python-agent.initramfs.orig ] || mv ironic-python-agent.initramfs ironic-python-agent.initramfs.orig
cp /tmp/ipa-qual.kernel    ironic-python-agent.kernel
cp /tmp/ipa-qual.initramfs ironic-python-agent.initramfs
ls -l ironic-python-agent.kernel ironic-python-agent.initramfs   # sizes = your build (~15M / ~254M)
REMOTE
```

## Step 7 — boot a node into the custom IPA

Inspection is the lightest op that reboots a node into IPA:

```sh
ssh -i "$KEY" "$BOX" 'kubectl annotate bmh node-0 -n metal3 inspect.metal3.io="" --overwrite'
ssh -i "$KEY" "$BOX" 'kubectl get bmh node-0 -n metal3 -w'   # available → inspecting
```

> Inspection completes quickly. The node tends to **stay up in the ramdisk**
> afterwards (the BMH is `online: true` and the disk is blank, so it keeps
> network-booting IPA). That is an *incidental* hold, not a managed one — see
> the validation plan for the real clean-wait hold.

## Step 8 — find the node IP and verify

Provisioning DHCP is the **`dnsmasq` container**, not libvirt — so map the
node's bootMAC to its lease there (`virsh net-dhcp-leases` is empty):

```sh
ssh -i "$KEY" "$BOX" 'bash -s' <<'REMOTE'
MAC=$(kubectl get bmh node-0 -n metal3 -o jsonpath='{.spec.bootMACAddress}')
docker exec dnsmasq cat /var/lib/dnsmasq/dnsmasq.leases | grep -i "$MAC"
# 3rd column is the IP, e.g. 172.22.0.69 (node-1 is .71)
REMOTE
```

SSH into the running ramdisk as `debug` and confirm the bake-in. **Use
`ssh -n`** for nested SSH — without it the inner ssh swallows the heredoc's
stdin and the rest of your script silently vanishes.

```sh
ssh -i "$KEY" "$BOX" 'bash -s' <<'REMOTE'
NODE=172.22.0.69
S="ssh -n -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i /tmp/ipa-debug debug@$NODE"
$S 'head -1 /etc/os-release; uname -r'                                   # CentOS Stream = the ramdisk, not a deployed OS
$S 'ls -l /usr/local/bin/qual-agent; /usr/local/bin/qual-agent --help | head -2'
$S 'sudo openssl x509 -in /etc/qual/tls/ca.crt -noout -subject'         # baked CA
$S 'sudo cat /etc/qual/qual-agent.env'                                  # baked orch/enroll addrs
$S 'systemctl is-enabled qual-agent.service; systemctl status qual-agent.service --no-pager | head -12'
$S 'sudo journalctl -u qual-agent.service --no-pager | tail -20'        # the agent's own logs
REMOTE
```

Integrity check (baked vs build-host artifact) — `sha256sum` on
`/usr/local/bin/qual-agent` and `/etc/qual/tls/ca.crt` should match
`~/qual-artifacts/`.

## Iterate

Rebuild → re-inject (`cp` over `html/images/ironic-python-agent.*`) →
re-trigger inspection. No need to touch the `.orig` backups again.

---

## Gotchas we actually hit

| Symptom | Cause / fix |
|---|---|
| `--element qual-agent` not found | run the builder from `~/ironic-python-agent-builder` (cwd-relative `./dib`); or pass `--elements-path`. |
| nested `ssh` in a heredoc eats the rest of the script | add **`-n`** to the inner ssh (or `< /dev/null`). |
| `virsh net-dhcp-leases` empty | provisioning DHCP is the **dnsmasq container** → read `/var/lib/dnsmasq/dnsmasq.leases`, map by bootMAC. |
| `virsh console node-0` "domain not found" | libvirt domain is `node_0` (underscore); BMH is `node-0`. |
| Ironic API → "speaking plain HTTP to an SSL port" | it's HTTPS+noauth: `curl -sk https://localhost:6385/... -H 'X-Auth-Token: noauth'`. |
| agent logs `nvidia-smi … not found`, retries forever | hardware collection runs before enroll and needs `nvidia-smi`; the GPU-less VM has none. Stub it / pass a GPU / use a dev path before enrollment testing. |
| restarting the `ironic` container reverts your IPA | it re-downloads the upstream image — never restart it after injecting. |
