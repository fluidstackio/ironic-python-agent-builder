# Clean-step timer verification (qualification Stage 0)

## What we're proving

Node qualification (including a multi-hour soak) is designed to run inside the
IPA ramdisk while the node is held in Ironic `cleaning`, gated by a long-running
`qualify_node` clean step. That only works if a node **stays in `CLEANWAIT` for
the full duration of the step** — i.e. the agent's heartbeats to the conductor
keep resetting the timeout, rather than `[conductor] clean_callback_timeout`
being an absolute ceiling measured from when the step started.

Reading the Ironic source says this holds: the cleanwait timeout task measures
against `node.provision_updated_at`, and each agent heartbeat in `CLEANWAIT`
calls `node.touch_provisioning()`, which bumps that field. This procedure
**confirms it empirically on the deployed Ironic version**, which is what we
actually rely on.

## The `sleep_test` step

The `qual-agent` element registers a `QualificationHardwareManager` exposing one
throwaway clean step, `sleep_test`, that just sleeps (default 1200s, override
with the `QUAL_SLEEP_TEST_SECONDS` env var) while logging liveness. It is
priority 0, so it never runs in automated cleaning — you invoke it explicitly
via manual cleaning.

## Procedure

1. **Build & publish** this ramdisk (the `gpu-noble` matrix variant builds the
   `qual-agent` element) and deploy it as the cleaning ramdisk for a test node.

2. **Shrink the timeout below the step duration** so the test actually crosses
   the threshold — otherwise it proves nothing. In `ironic.conf`:

   ```ini
   [conductor]
   clean_callback_timeout = 300   # 5 minutes
   ```

   Restart the conductor. (`sleep_test` defaults to 1200s = 20 min, comfortably
   past 5 min.)

3. **Trigger manual cleaning** with just this step:

   ```bash
   openstack baremetal node clean <node> \
     --clean-steps '[{"interface": "deploy", "step": "sleep_test"}]'
   ```

4. **Watch the Ironic-side state** (not the agent's own logs — the conductor's
   view is what the claim is about):

   ```bash
   watch -n5 'openstack baremetal node show <node> -f value \
     -c provision_state -c provision_updated_at -c last_error'
   ```

## Reading the result

- **Pass (expected):** `provision_state` stays `clean wait`,
  `provision_updated_at` keeps advancing on the agent's heartbeat cadence, no
  `last_error`, and the node completes cleaning at ~20 min despite the 5-min
  timeout. Heartbeats sustain the hold → the soak-in-ramdisk architecture is
  sound. Restore `clean_callback_timeout` to a value above your worst-case
  qualification duration (soak + margin).
- **Fail:** node flips to `clean failed` around 5 min regardless of heartbeats.
  The timeout is an absolute cap on this version → it must be raised above the
  full qualification duration, and the architecture needs rethinking for soak.

`provision_updated_at` advancing while the step sleeps is the direct tell that
the timer is being reset by heartbeats.
