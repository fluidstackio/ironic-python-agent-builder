"""qualOS gate: an automated clean step that holds the node in the IPA ramdisk
until qualification signals completion.

This is the prototype of the production `qual_gate`. The node boots the IPA
ramdisk ("qualOS"); this step runs **automatically** as part of Ironic
*automated* cleaning (priority > 0 — no operator API call, no per-node step
injection), parking the node in `clean wait` while the qual-agent runs
qualification against the orchestrator. It releases only on an **external
signal**: the qual-agent writes a verdict file when the orchestrator reaches a
terminal state.

    orchestrator --(gRPC terminal verdict)--> qual-agent
        --> writes /run/qual/verdict ("passed" | "failed")
            --> this step returns success  -> cleaning continues -> node proceeds
            --> or raises CleaningError    -> `clean failed`     -> node held for triage

Release contract (the qual-agent owns the writer side; this step owns the
reader side):
    echo passed > /run/qual/verdict     # qualification succeeded -> continue
    echo failed > /run/qual/verdict     # qualification failed    -> hold for triage

NOTE: the step name must NOT be one of Ironic's reserved flow-control names
(power_on/power_off/reboot/hold/wait) or it is silently dropped during
validation. THROWAWAY / SANDBOX element — folds into the qual-agent element when
productionized.
"""

import logging
import os
import time

from ironic_python_agent import errors
from ironic_python_agent import hardware

LOG = logging.getLogger(__name__)

# Written by the qual-agent when the orchestrator reaches a terminal state.
VERDICT_FILE = '/run/qual/verdict'
POLL_SECONDS = 10


class QualHoldHardwareManager(hardware.GenericHardwareManager):
    """Adds the qualOS gate clean step; otherwise identical to Generic."""

    HARDWARE_MANAGER_NAME = 'QualHoldHardwareManager'
    HARDWARE_MANAGER_VERSION = '2'

    def evaluate_hardware_support(self):
        # Always active in the sandbox so the gate runs on the GPU-less VM.
        # (A real manager would gate on DMI / accelerator presence.)
        return hardware.HardwareSupport.SERVICE_PROVIDER

    def get_clean_steps(self, node, ports):
        steps = super().get_clean_steps(node, ports)
        steps.append({
            'step': 'qual_hold',
            # priority > 0 => runs AUTOMATICALLY during automated cleaning
            # (the ZTP/metal3 lifecycle triggers it; no manual --clean-steps).
            # High value so it runs before the destructive erase_* steps:
            # qualify first, then (on pass) cleaning continues.
            'priority': 100,
            'interface': 'deploy',
            'reboot_requested': False,
            'abortable': True,
        })
        return steps

    def qual_hold(self, node, ports):
        LOG.info('qual gate: holding in qualOS; awaiting external verdict at %s',
                 VERDICT_FILE)
        waited = 0
        while not os.path.exists(VERDICT_FILE):
            time.sleep(POLL_SECONDS)
            waited += POLL_SECONDS
            if waited % 60 == 0:
                LOG.info('qual gate: still holding (%ss elapsed; '
                         'clean_callback_timeout resets on each heartbeat)',
                         waited)

        verdict = ''
        try:
            with open(VERDICT_FILE) as f:
                verdict = f.read().strip().lower()
        except OSError as e:
            raise errors.CleaningError(
                'qual gate: could not read verdict file %s: %s'
                % (VERDICT_FILE, e))

        LOG.info('qual gate: verdict=%r after %ss', verdict, waited)
        if verdict == 'passed':
            # success -> cleaning continues -> node proceeds out of qualOS
            return
        # anything else -> fail cleaning -> node held in `clean failed` for triage
        raise errors.CleaningError(
            'qualification did not pass (verdict=%r)' % verdict)
