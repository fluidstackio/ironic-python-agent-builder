# Testing IPA changes in a local VM sandbox (no hardware, no prod)

A self-contained loop to **prove that what you bake into the IPA ramdisk
actually shows up on a booted node** — using VMs as fake bare-metal hosts. No
physical hardware, no real BMCs, no prod clusters.

Same stack as production, each physical piece swapped for a local emulated one:

| Production | VM sandbox |
|---|---|
| Physical host | **libvirt/QEMU VM** |
| BMC | **sushy-tools** (Redfish BMC emulator) |
| Mgmt k8s + Ironic | **kind** mgmt cluster + BMO + Ironic (via `metal3-dev-env`) |
| Published IPA image | **your locally-built IPA** from *this* repo |

Because the nodes are normal VMs, they boot normally — this sandbox validates
**IPA content and clean/deploy behavior** quickly and with zero prod blast
radius.

---

## Phase 0 — a Linux host with KVM

> ⚠️ **Won't run on macOS** (no KVM) and not in a plain EC2 Nitro VM (no nested
> virt). Use a **Linux box with hardware virtualization**: a spare Linux
> machine, a GCP VM with `--enable-nested-virtualization`, or an **AWS
> bare-metal** (`*.metal`) instance.

This directory ships helper scripts:

- **`testing-ipa-with-vm.sh`** — launches an AWS `c5.metal` host (handles the
  no-default-VPC case, opens SSH, installs KVM + libvirt, clones
  `metal3-dev-env` via cloud-init) and records every created resource to
  `sandbox-resources.env` / `sandbox-resources.log`.
- **`cleanup-sandbox.sh`** — tears down everything it created (instances tagged
  `Name=ipa-sandbox`, the `ipa-sandbox-ssh-*` security group). Tag-based, prompts
  first.

```sh
# from your laptop (fill in the vars at the top of the script first)
./ipa-dev/testing-ipa-with-vm.sh        # prints the ssh command + records state
# ... later, when done:
./ipa-dev/cleanup-sandbox.sh
```

After SSH-ing in, wait for cloud-init, then confirm KVM:

```sh
cat ~/SANDBOX_READY        # written when cloud-init completes
ls -l /dev/kvm             # virtualization present
```

> `chmod 600` your `.pem` locally or SSH refuses it ("bad permissions").

---

## Phase 1 — stand up the sandbox (`metal3-dev-env`)

cloud-init already cloned it. Configure for the **Redfish** BMC emulator:

```sh
cd ~/metal3-dev-env
cat > config_${USER}.sh <<'EOF'
# NUM_NODES must be >= CONTROL_PLANE_MACHINE_COUNT + WORKER_MACHINE_COUNT
# (defaults 1 + 1), so use at least 2. We only use one for the IPA test.
export NUM_NODES=2
export BMC_DRIVER=redfish
export NODES_MEMORY=8192
export NODES_CPU=2
export IMAGE_OS=ubuntu
EOF
make                       # builds kind + BMO + Ironic + sushy-tools + node VMs
```

> **`make` fails "incorrect number of nodes"** → `NUM_NODES` < CP+worker. Use 2.

When it finishes:

```sh
kubectl get bmh -A         # node-0 / node-1 → 'available'
```

> **Key fact:** metal3-dev-env's default `USE_IRSO=false` runs **Ironic as local
> Docker containers on the host** (`docker ps` → `ironic`, `httpd`, `dnsmasq`,
> `sushy-tools`, …), **not** as Kubernetes pods. So you inject the IPA via a
> **host directory**, and there is no "ironic pod" to `kubectl cp` into.

---

## Phase 2 — get this repo onto the box

```sh
# from your laptop — rsync your working branch up (skip .git/ for speed)
rsync -az --delete --exclude '.git' --exclude 'ipa-dev' \
  -e "ssh -i ~/.ssh/<your-key>.pem" \
  ~/dev/ironic-python-agent-builder/ \
  ubuntu@<EC2_IP>:~/ironic-python-agent-builder/
```

```sh
# on the box
cd ~/ironic-python-agent-builder
python3 -m venv ~/.venv/ipa && . ~/.venv/ipa/bin/activate
# PBR_VERSION lets the install work without .git (this repo uses pbr,
# which otherwise needs git metadata to compute its version):
PBR_VERSION=0.0.1 pip install .
```

---

## Phase 3 — build YOUR IPA (with a bake-in marker)

We bake an obvious marker so success is unambiguous, **and** add the `devuser`
element so you can SSH into the running ramdisk to inspect it. Once this loop
works, **swap `--element test-marker` for your real element.**

```sh
# debug user for SSH into the ramdisk
ssh-keygen -t ed25519 -f /tmp/ipa-debug -N '' -C ipa-debug
export DIB_DEV_USER_USERNAME=debug
export DIB_DEV_USER_AUTHORIZED_KEYS=/tmp/ipa-debug.pub
export DIB_DEV_USER_PWDLESS_SUDO=yes

# a trivial element — DIB copies an element's static/ tree into the image root
mkdir -p dib/test-marker/static/etc
echo "MY-IPA-MARKER v1 — bake-in works" > dib/test-marker/static/etc/ipa-bake-marker
: > dib/test-marker/element-deps

ironic-python-agent-builder --lzma --output /tmp/ipa-test \
  --release 9-stream --branch master \
  --element test-marker --element devuser --verbose centos
# → /tmp/ipa-test.kernel + /tmp/ipa-test.initramfs
```

---

## Phase 4 — inject your IPA into the sandbox's Ironic

The served files live in `/opt/metal3-dev-env/ironic/html/images/` as symlinks
into the downloaded upstream tarball. Replace them with your build:

```sh
cd /opt/metal3-dev-env/ironic/html/images/
mv ironic-python-agent.kernel    ironic-python-agent.kernel.orig
mv ironic-python-agent.initramfs ironic-python-agent.initramfs.orig
cp /tmp/ipa-test.kernel    ironic-python-agent.kernel
cp /tmp/ipa-test.initramfs ironic-python-agent.initramfs
ls -l ironic-python-agent.kernel ironic-python-agent.initramfs   # sizes = your build
```

> The dir is `ubuntu`-owned (no sudo). Leave the `.headers` symlink. **Don't
> restart the `ironic` container** or it re-downloads and clobbers your files.

---

## Phase 5 — boot a node into your IPA

Trigger **inspection** — the lightest op that re-boots the node into your IPA:

```sh
kubectl annotate bmh node-0 -n metal3 inspect.metal3.io="" --overwrite
kubectl get bmh -A -w        # 'available' → 'inspecting'
```

> Testing a **clean-step** change (not just file presence)? Those run during
> **cleaning**, not inspection — set the BMH `automatedCleaningMode: metadata`
> and trigger cleaning instead, then watch the step run.

---

## Phase 6 — verify

Find the node's IP. The provisioning DHCP is served by the **`dnsmasq`
container** (not libvirt), so the **node console** is the most reliable place —
it prints the agent's interface IPs:

```sh
sudo virsh console node_0    # libvirt domain uses underscore: node_0 (BMH is node-0)
# look for: ironic-python-agent ... 'logicalname': 'enp1s0', ... 'ip': '172.22.0.NN'
# (enp1s0 = the bootMAC NIC on the provisioning net). Ctrl-]  to exit.
```

SSH into the running ramdisk as the `debug` user and check your bake-in:

```sh
ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i /tmp/ipa-debug debug@<NODE_IP> \
  'head -1 /etc/os-release; echo MARKER:; cat /etc/ipa-bake-marker'
```

✅ **Prints `MY-IPA-MARKER v1 …` → bake-in proven**, end to end: your
locally-built IPA booted on the node with your file in it. (`CentOS Stream`
confirms it's *your IPA ramdisk*, not a deployed OS.)

Then swap `--element test-marker` for your real element and repeat — same proof.

---

## Phase 7 — iterate

```sh
# rebuild → re-inject → re-trigger
ironic-python-agent-builder --lzma --output /tmp/ipa-test --release 9-stream \
  --branch master --element test-marker --element devuser --verbose centos
cp /tmp/ipa-test.kernel    /opt/metal3-dev-env/ironic/html/images/ironic-python-agent.kernel
cp /tmp/ipa-test.initramfs /opt/metal3-dev-env/ironic/html/images/ironic-python-agent.initramfs
kubectl annotate bmh node-0 -n metal3 inspect.metal3.io="" --overwrite
```

## Phase 8 — cleanup

```sh
cd ~/metal3-dev-env && make clean       # on the box: VMs, kind, sushy-tools
./ipa-dev/cleanup-sandbox.sh            # from your laptop: terminate the EC2 + SG
```

---

## Troubleshooting (gotchas we actually hit)

| Symptom | Cause / fix |
|---|---|
| `create-security-group: No default VPC` | locked-down account — the launch script auto-discovers a VPC/subnet, or set `VPC_ID`/`SUBNET_ID`. |
| `Permission denied (publickey)` + "bad permissions" | `chmod 600 ~/.ssh/<key>.pem`. |
| `pip install .` → pbr "requires sdist or git" | rsync'd without `.git` → use `PBR_VERSION=0.0.1 pip install .`. |
| `make` → "incorrect number of nodes" | `NUM_NODES` must be ≥ CP+worker (≥ 2). |
| no `ironic` pod (`kubectl get pods`) | `USE_IRSO=false` → Ironic runs as **Docker** containers; inject via `/opt/metal3-dev-env/ironic/html/images/`. |
| `virsh net-dhcp-leases` empty | provisioning DHCP is the **dnsmasq container**, not libvirt — get the node IP from the **console** instead. |
| `virsh console node-0` "domain not found" | libvirt domain is `node_0` (underscore); BMH is `node-0`. |
| node never DHCPs / no agent | watch the console — if the kernel panics, the built ramdisk is bad (check `--release`/distro). |