# Container image for running VillageSQL prebuilt tests on Cloudflare Containers.
# Ubuntu 25.10: the VillageSQL tarballs need glibc 2.42 (24.04 has 2.39).
FROM ubuntu:25.10

ENV DEBIAN_FRONTEND=noninteractive

# Tooling for the scripts, plus the shared libraries mysqld links against.
# lsof/iproute2 are used by the installer's port check; libcurl is needed by
# the Percona keyring components.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gh jq tar gzip procps iproute2 lsof util-linux \
      libaio1t64 libnuma1 libncurses6 libtirpc3t64 libssl3t64 libcurl4t64 \
 && rm -rf /var/lib/apt/lists/*

# The installer refuses to run as root, so the tests run as this user.
RUN useradd --create-home --shell /bin/bash runner \
 && mkdir -p /workspace \
 && chown runner:runner /workspace

# Cloudflare Sandbox shim, which lets the Worker exec commands in a custom
# image. Bump the tag when Cloudflare publishes a newer one.
COPY --from=docker.io/cloudflare/sandbox:1.0.0 /usr/local/bin/sandbox-shim /usr/local/bin/sandbox-shim

WORKDIR /workspace
CMD ["sleep", "infinity"]
