==========
qual-agent
==========
Integrates GPU node qualification into the IPA ramdisk.

Qualification runs **inside the ephemeral ramdisk** while the node is held in
Ironic ``cleaning`` — single-node tests, then SU-scoped cohort/cluster tests,
then a multi-hour soak — and gates provisioning: a node only leaves cleaning
once it is qualified. The mechanism is an IPA **clean step** exposed by a custom
hardware manager (``QualificationHardwareManager``), registered the same way as
``fluidstack-ironwood`` registers its manager.

The clean step runs during **automated cleaning** (priority 10), so it triggers
automatically when a BMH enters the cleaning lifecycle — no manual API call is
needed. The ``BareMetalHost`` must have ``automatedCleaningMode: metadata`` (not
``disabled``) for this to fire.

Stage 0 (this commit) — verification spike
-------------------------------------------
Because the soak can run for hours, the whole approach depends on one Ironic
behaviour: a node must stay in ``CLEANWAIT`` for the full duration of a
long-running clean step (the agent's heartbeats must sustain
``[conductor] clean_callback_timeout`` rather than it being an absolute cap).

This element currently ships only a ``sleep_test`` clean step to **prove that
behaviour on real hardware** before the rest is built on it. See
``docs/qual-clean-timer-verification.md`` for the test procedure and
``docs/building-and-testing-ipa.md`` for how to build and deploy the image.

Later stages replace ``sleep_test`` with the real ``qualify_node`` step (which
execs the baked ``qual-agent`` binary and gates cleaning on its exit code), bake
the binary + Fluidstack Root CA + config, and tighten
``evaluate_hardware_support`` to GPU hosts.

Contents
--------
* ``static/usr/lib/python3/dist-packages/qualification_hardware_manager.py`` —
  the hardware manager (Stage 0: ``sleep_test`` only).
* ``post-install.d/99-qual-hardware-manager`` — copies the manager into the IPA
  virtualenv and registers it as an ``ironic_python_agent.hardware_managers``
  entry point.

Configuration
-------------
* ``QUAL_SLEEP_TEST_SECONDS`` — override the sleep duration (default 1200 s).
* To disable on specific clusters without rebuilding::

    [conductor]
    clean_step_priority_override = deploy.sleep_test:0
