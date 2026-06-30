# qual-agent build-time configuration. All overridable from the environment.

# Orchestrator mTLS endpoint (host:port) — fleet-wide, baked into the runtime
# env file by install.d/55-qual-agent-config and passed to the agent as
# --orchestrator. The agent dials gRPC, so this is a host:port, not a URL.
export QUAL_ORCH_ADDR=${QUAL_ORCH_ADDR:-qual-orchestrator.example.com:9443}

# Enrollment endpoint (host:port) — the server-auth-TLS listener the agent calls
# at boot to obtain its client cert. Passed to the agent as --enroll-addr.
export QUAL_ENROLL_ADDR=${QUAL_ENROLL_ADDR:-qual-orchestrator.example.com:9444}

# Path on the BUILD HOST to the qual-agent binary (pulled from S3 by the CI
# job before the build). Copied into the image. Unset → binary not installed
# (see extra-data.d/16-qual-agent-binary-copy and install.d/40-qual-agent-binary).
export DIB_QUAL_AGENT_FILE=${DIB_QUAL_AGENT_FILE:-}

# Path on the BUILD HOST to the Fluidstack Root CA (PEM), staged by
# extra-data.d/15-qual-ca-copy and baked to /etc/qual/tls/ca.crt.
export DIB_QUAL_CA_FILE=${DIB_QUAL_CA_FILE:-}

# Informational version tag.
export DIB_QUAL_AGENT_VERSION=${DIB_QUAL_AGENT_VERSION:-1.4.0}
