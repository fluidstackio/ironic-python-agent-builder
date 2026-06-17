# Clean-step timer verification (qualification Stage 0)

## What we're proving

Node qualification (including a multi-hour soak) runs inside the IPA ramdisk
while the node is held in Ironic `cleaning`, gated by a long-running clean step.
That only works if a node **stays in `CLEANWAIT` for the full duration of the
step** — the agent's heartbeats must keep resetting `clean_callback_timeout`
rather than the timeout being an absolute ceiling.

Reading the Ironic source says this holds: `_check_cleanwait_timeouts` measures
against `node.provision_updated_at`, and each agent heartbeat in CLEANWAIT calls
`node.touch_provisioning()`, which bumps that field. This procedure **confirms
it empirically on the deployed Ironic version**.

## How it works

The `qual-agent` DIB element registers a `QualificationHardwareManager` with a
`sleep_test` clean step at **priority 10** (automated cleaning). When a node
enters cleaning, IPA boots in the ramdisk, discovers the hardware manager, and
runs `sleep_test` — which just sleeps for a configurable duration (default
1200 s) while logging liveness every 30 s.

IPA runs clean steps in a background thread while its main heartbeat loop
continues reporting to the conductor. If heartbeats sustain CLEANWAIT, the node
stays in `clean wait` for the full sleep. If they don't, the node times out to
`clean failed` when `clean_callback_timeout` elapses.

## Prerequisites

- An IPA ramdisk built with the `qual-agent` element (see
  [building-and-testing-ipa.md](building-and-testing-ipa.md)).
- A test node managed by Ironic (BMH resource in Kubernetes).
- Access to the Ironic API (either via `kubectl exec` into the ironic pod or
  via the `baremetal` CLI with auth configured).

## Procedure

### 1. Shrink the timeout

Edit `ironic.conf` on the conductor so the timeout is well below the step
duration. The default is 1800 s; set it to 300 s (5 min) so the 20-min sleep
crosses the threshold.

**Important:** `OS_CONDUCTOR__CLEAN_CALLBACK_TIMEOUT` env vars do NOT work —
oslo.config does not read env overrides in this deployment. You must edit the
config file directly:

```bash
NS=baremetal-operator-system
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=ironic -o jsonpath='{.items[0].metadata.name}')

kubectl -n $NS exec $POD -c ironic -- sed -i \
  's/^clean_callback_timeout.*/clean_callback_timeout = 300/' \
  /etc/ironic/ironic.conf
```

Then restart the pod so the conductor picks up the change:

```bash
kubectl -n $NS delete pod $POD
# Wait for the new pod
kubectl -n $NS rollout status deploy/ironic-service
```

After restart, re-copy the qualtest ramdisk into the pod (the restart reverts to
the default ramdisk — see step 2).

### 2. Deploy the qualtest ramdisk

The `ramdisk-downloader` init container fetches the IPA image from S3 on every
pod start. For one-off testing, the easiest approach is to replace the served
files directly:

```bash
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=ironic -o jsonpath='{.items[0].metadata.name}')

kubectl -n $NS cp ipa-ubuntu-noble-qualtest.kernel  $POD:/shared/html/images/ironic-python-agent.kernel -c httpd
kubectl -n $NS cp ipa-ubuntu-noble-qualtest.initramfs $POD:/shared/html/images/ironic-python-agent.initramfs -c httpd

# Verify
kubectl -n $NS exec $POD -c httpd -- ls -la /shared/html/images/ironic-python-agent.*
```

Both files should be regular files (not symlinks) owned by `ironic`, with at
least `0644` permissions.

### 3. Configure the BMH for automated cleaning

The test node's BareMetalHost must have automated cleaning enabled:

```yaml
spec:
  automatedCleaningMode: metadata   # NOT 'disabled'
```

If the BMH currently has `automatedCleaningMode: disabled`, edit it:

```bash
kubectl -n <bmh-namespace> patch bmh <name> --type merge \
  -p '{"spec": {"automatedCleaningMode": "metadata"}}'
```

### 4. Trigger cleaning

Delete and re-apply the BMH (or remove the `spec.image` to unprovision). The
node will go through:

```
registering → inspecting → manageable → cleaning → clean wait → ...
```

During `cleaning`, Ironic boots the IPA ramdisk. The `QualificationHardwareManager`
is discovered, and `sleep_test` runs as an automated clean step.

If the node is currently provisioned, unprovision it first — automated cleaning
also runs during the `deleting → available` transition:

```bash
# From inside the ironic pod:
UUID=<node-uuid>
curl -X PUT -H "Content-Type: application/json" \
  -H "X-OpenStack-Ironic-API-Version: 1.22" \
  http://localhost:6385/v1/nodes/$UUID/states/provision \
  -d '{"target": "deleted"}'
```

### 5. Watch

Monitor `provision_state` and `provision_updated_at` from inside the ironic pod:

```bash
UUID=<node-uuid>
while true; do
  curl -s http://localhost:6385/v1/nodes/$UUID | \
    grep -o '"provision_state": "[^"]*"\|"provision_updated_at": "[^"]*"'
  echo "---"
  sleep 30
done
```

Or from outside the pod, watch the BMH:

```bash
kubectl get bmh <name> -n <namespace> -w
```

## Reading the result

- **Pass (expected):** `provision_state` stays `clean wait`,
  `provision_updated_at` keeps advancing on the heartbeat cadence, no
  `last_error`, and the node completes cleaning at ~20 min despite the 5-min
  timeout. Heartbeats sustain the hold.

- **Fail:** node flips to `clean failed` around 5 min regardless of
  heartbeats. The timeout is an absolute cap and we need to raise
  `clean_callback_timeout` above the worst-case qualification duration.

`provision_updated_at` advancing while the step sleeps is the direct tell.

## Environment override

To shorten the test without rebuilding the image, set the
`QUAL_SLEEP_TEST_SECONDS` env var in the IPA ramdisk (e.g. via
`ipa-extra-hardware-env` or kernel cmdline). Default is 1200.

To disable the step on clusters where it shouldn't run during automated
cleaning, add to `ironic.conf`:

```ini
[conductor]
clean_step_priority_override = deploy.sleep_test:0
```

## Lessons learned (wdl101 2026-06-17)

1. **`kubectl set env -c` does not work for init containers.** The
   `ramdisk-downloader` is an init container; `kubectl set env deploy/ironic-service
   -c ramdisk-downloader IPA_FLAVOR=...` silently targets regular containers
   only. Use `kubectl cp` to replace the served ramdisk files directly.

2. **oslo.config env var overrides are not enabled.** Setting
   `OS_CONDUCTOR__CLEAN_CALLBACK_TIMEOUT=300` as an env var on the `ironic`
   container has no effect. The conductor reads `ironic.conf` directly. Edit the
   config file inside the pod, or patch the ConfigMap that templates it.

3. **Manual clean via the Ironic API may not reboot the node.** On the wdl101
   Quanta node (using `redfish-grpc-proxy`), triggering manual clean via
   `PUT .../states/provision {"target": "clean"}` moved the node to `clean wait`
   but the IPA never booted — the node stayed on HDD boot and no heartbeats
   arrived. Using automated cleaning via BMH lifecycle (which goes through the
   full Metal3 controller path) is more reliable.

4. **The `baremetal` CLI is not available inside the ironic container.** Use
   `curl http://localhost:6385/v1/...` to interact with the Ironic API from
   inside the pod. `python3` and `jq` are also absent; use `grep -o` to parse
   JSON fields from curl output.
