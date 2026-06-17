"""
Qualification hardware manager for Ironic Python Agent.

STAGE 0 — verification spike.

Exposes a ``sleep_test`` clean step that runs during automated cleaning to
verify that a node stays in CLEANWAIT for the full duration of a long-running
step. The production ``qualify_node`` step (Stage 2) replaces this and execs the
qual-agent binary, which connects to the orchestrator and blocks until the full
qualification pipeline (single-node, cohort, soak) reaches a terminal verdict.

See docs/qualification-workflow.md for the full architecture and
docs/qual-clean-timer-verification.md for how to run this verification test.
"""

import logging
import os
import time

from ironic_python_agent import hardware

LOG = logging.getLogger(__name__)

_DEFAULT_SLEEP_SECONDS = 1200  # 20 minutes
_SLEEP_ENV = 'QUAL_SLEEP_TEST_SECONDS'
_LOG_INTERVAL_SECONDS = 30


class QualificationHardwareManager(hardware.GenericHardwareManager):
    """Adds qualification clean steps to IPA.

    Stage 0 ships only the ``sleep_test`` verification step.
    """

    HARDWARE_MANAGER_NAME = 'QualificationHardwareManager'
    HARDWARE_MANAGER_VERSION = '1'

    def evaluate_hardware_support(self):
        """Activate broadly during the spike so the timer test can run on any
        available node. Tightened to GPU hosts once ``qualify_node`` lands.
        """
        return hardware.HardwareSupport.SERVICE_PROVIDER

    def get_clean_steps(self, node, ports):
        """Expose ``sleep_test`` as an automated clean step (priority > 0).

        This runs automatically when a node enters cleaning (e.g. after
        unprovisioning, or on first registration with automatedCleaningMode
        enabled on the BMH). The production ``qualify_node`` step will use the
        same model: automated cleaning gates provisioning so every node must
        pass qualification before it becomes available.

        To disable for specific clusters, set the conductor config override:
            clean_step_priority_override = deploy.sleep_test:0
        """
        return [{
            'step': 'sleep_test',
            'priority': 10,
            'interface': 'deploy',
            'reboot_requested': False,
            'abortable': True,
        }]

    def sleep_test(self, node, ports):
        """Sleep for a configurable duration, logging liveness periodically.

        IPA runs clean steps in a background thread while its heartbeat loop
        keeps reporting to the conductor. This blocking sleep is the condition
        under test: the node should remain in CLEANWAIT for the whole duration
        if heartbeats sustain the callback timer.
        """
        try:
            seconds = int(os.environ.get(_SLEEP_ENV, _DEFAULT_SLEEP_SECONDS))
        except ValueError:
            seconds = _DEFAULT_SLEEP_SECONDS

        LOG.info('sleep_test: starting; sleeping %d seconds '
                 '(override with %s)', seconds, _SLEEP_ENV)
        elapsed = 0
        while elapsed < seconds:
            chunk = min(_LOG_INTERVAL_SECONDS, seconds - elapsed)
            time.sleep(chunk)
            elapsed += chunk
            LOG.info('sleep_test: alive at %d/%d seconds', elapsed, seconds)
        LOG.info('sleep_test: completed after %d seconds', seconds)
