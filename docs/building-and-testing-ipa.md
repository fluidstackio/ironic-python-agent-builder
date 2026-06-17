# Building and testing the qualification IPA ramdisk

Step-by-step instructions for building an IPA image with the `qual-agent`
element and deploying it for testing.

## Build the image

The image must be built on **Linux** (debootstrap, chroot, and GNU getopt are
required). macOS will not work.

### 1. Install dependencies

On Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y \
  python3-venv git curl \
  debootstrap dosfstools gdisk genisoimage kpartx parted \
  qemu-utils squashfs-tools
```

### 2. Install ironic-python-agent-builder

```bash
git clone https://github.com/fluidstackio/ironic-python-agent-builder.git
cd ironic-python-agent-builder

python3 -m venv ~/.local/ipa-builder
~/.local/ipa-builder/bin/pip install . \
  -c https://releases.openstack.org/constraints/upper/2026.1
export PATH="$HOME/.local/ipa-builder/bin:$PATH"
```

### 3. Build

```bash
ironic-python-agent-builder \
  --lzma \
  --output ipa-ubuntu-noble-qualtest \
  --release noble \
  --branch stable/2026.1 \
  --element qual-agent \
  --verbose \
  ubuntu
```

**Common mistakes:**
- Missing `--element qual-agent` — the hardware manager won't be included.
- Using a git branch name (e.g. `qual-clean-timer-spike`) instead of an
  OpenStack IPA branch (e.g. `stable/2026.1`) for `--branch`.
- Running on macOS — requires Linux.

### 4. Verify the build

Check the build log for:

```
Installed qualification_hardware_manager.py -> ...
Registered QualificationHardwareManager in ...entry_points.txt
```

Output files:

```
ipa-ubuntu-noble-qualtest.kernel      # ~15 MB
ipa-ubuntu-noble-qualtest.initramfs   # ~500 MB
ipa-ubuntu-noble-qualtest.sha256
ipa-ubuntu-noble-qualtest.d/          # build metadata
```

### 5. Package and upload to S3

```bash
tar czvf ipa-ubuntu-noble-qualtest.tar.gz \
  ipa-ubuntu-noble-qualtest.kernel \
  ipa-ubuntu-noble-qualtest.initramfs \
  ipa-ubuntu-noble-qualtest.sha256 \
  ipa-ubuntu-noble-qualtest.d

sha256sum ipa-ubuntu-noble-qualtest.tar.gz > ipa-ubuntu-noble-qualtest.tar.gz.sha256

aws s3 cp ipa-ubuntu-noble-qualtest.tar.gz \
  s3://fish-artifacts-867207177450/fluidstack/finz/ipa/
aws s3 cp ipa-ubuntu-noble-qualtest.tar.gz.sha256 \
  s3://fish-artifacts-867207177450/fluidstack/finz/ipa/
```

If the bastion lacks `aws` CLI: install via
`curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip`,
unzip, `sudo ./aws/install`. If no AWS credentials are available, use SSO
short-term creds from the AWS access portal (`S3ArtifactsReadWrite` role).

## Deploy to a test cluster

### Option A: Point ironic to the new image (persistent)

Edit the `ironic-service` deployment to change the init container's env:

```yaml
# ramdisk-downloader init container env:
IPA_FLAVOR: ubuntu-noble
IPA_BRANCH: qualtest
```

**Note:** `kubectl set env -c <init-container>` does not work for init
containers. You must edit the deployment spec directly or patch the Helm values.
After the change, restart the deployment.

### Option B: Direct file replacement (ephemeral, simpler for one-off tests)

Copy the ramdisk files directly into the running ironic pod, replacing the
served files. This survives until the pod restarts.

```bash
NS=baremetal-operator-system
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=ironic -o jsonpath='{.items[0].metadata.name}')

kubectl -n $NS cp ipa-ubuntu-noble-qualtest.kernel \
  $POD:/shared/html/images/ironic-python-agent.kernel -c httpd
kubectl -n $NS cp ipa-ubuntu-noble-qualtest.initramfs \
  $POD:/shared/html/images/ironic-python-agent.initramfs -c httpd

# Verify they're real files (not symlinks) with correct permissions
kubectl -n $NS exec $POD -c httpd -- ls -la /shared/html/images/ironic-python-agent.*
```

### Configure the timeout for testing

To shrink `clean_callback_timeout` below the `sleep_test` duration (so the test
crosses the threshold), edit `ironic.conf` directly:

```bash
kubectl -n $NS exec $POD -c ironic -- sed -i \
  's/^clean_callback_timeout.*/clean_callback_timeout = 300/' \
  /etc/ironic/ironic.conf

# Restart the pod to pick up the change
kubectl -n $NS delete pod $POD
```

After restart, re-copy the ramdisk files (Option B) since the new pod starts
with the default image.

**Do not use env vars** — `OS_CONDUCTOR__CLEAN_CALLBACK_TIMEOUT` is silently
ignored by this deployment's oslo.config setup.

## Run the test

### 1. Ensure the BMH has automated cleaning enabled

```bash
kubectl -n <ns> patch bmh <name> --type merge \
  -p '{"spec": {"automatedCleaningMode": "metadata"}}'
```

### 2. Trigger cleaning

If the node is provisioned, delete and re-apply the BMH, or unprovision via the
Ironic API. Automated cleaning runs during the state transition.

### 3. Monitor

From inside the ironic pod (`kubectl exec`):

```bash
UUID=<node-uuid>
while true; do
  curl -s http://localhost:6385/v1/nodes/$UUID | \
    grep -o '"provision_state": "[^"]*"\|"provision_updated_at": "[^"]*"'
  echo "---"
  sleep 30
done
```

Or from outside, watch the BMH:

```bash
kubectl get bmh <name> -n <namespace> -w
```

See [qual-clean-timer-verification.md](qual-clean-timer-verification.md) for how
to interpret the results.

## Useful commands inside the ironic pod

The ironic container has `curl` but lacks `baremetal`, `python3`, and `jq`. Use
`curl` + `grep -o` to interact with the Ironic API:

```bash
# List all nodes
curl -s http://localhost:6385/v1/nodes | \
  grep -o '"uuid": "[^"]*"\|"provision_state": "[^"]*"'

# Show a specific node
curl -s http://localhost:6385/v1/nodes/$UUID | \
  grep -o '"provision_state": "[^"]*"\|"provision_updated_at": "[^"]*"\|"last_error": [^,]*'

# Change provision state
curl -X PUT -H "Content-Type: application/json" \
  -H "X-OpenStack-Ironic-API-Version: 1.22" \
  http://localhost:6385/v1/nodes/$UUID/states/provision \
  -d '{"target": "<target>"}'
# Targets: "manage", "provide", "clean", "deleted"
```
