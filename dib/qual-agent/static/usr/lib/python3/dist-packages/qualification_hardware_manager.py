"""
Qualification hardware manager for Ironic Python Agent.

STAGE 0 — verification spike.

This exposes a single throwaway ``sleep_test`` clean step whose only purpose is
to verify that a node stays in ``CLEANWAIT`` for the full duration of a
long-running clean step — i.e. that the agent's heartbeats to the conductor
sustain ``[conductor] clean_callback_timeout`` rather than the timeout being an
absolute ceiling from when the step started.

If that holds, the qualification pipeline (single-node -> cohort -> cluster ->
multi-hour soak) can run entirely inside this ramdisk while the node is held in
cleaning, gated by a real ``qualify_node`` clean step that replaces this one in a
later stage. See docs/qual-clean-timer-verification.md for how to run the test.
"""

import logging
import os
import time

from ironic_python_agent import hardware

LOG = logging.getLogger(__name__)

# Default sleep for the verification step. Override at runtime with the env var
# below to make the experiment shorter/longer without rebuilding the image.
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
        available node. This is tightened to GPU hosts once the real
        ``qualify_node`` step lands.
        """
        return hardware.HardwareSupport.SERVICE_PROVIDER

    def get_clean_steps(self, node, ports):
        """Expose ``sleep_test`` at priority 0 so it is NOT part of automated
        cleaning — it is invoked explicitly via manual cleaning, which is also
        the model the real per-SU qualification trigger will use.
        """
        return [{
            'step': 'sleep_test',
            'priority': 0,
            'interface': 'deploy',
            'reboot_requested': False,
            'abortable': True,
        }]

    def sleep_test(self, node, ports):
        """Sleep for a configurable duration, logging liveness periodically.

        IPA runs clean steps in a background command thread while its heartbeat
        loop keeps reporting to the conductor, so this blocking sleep is exactly
        the condition under test: the node should remain in CLEANWAIT for the
        whole duration if heartbeats sustain the callback timer.
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
