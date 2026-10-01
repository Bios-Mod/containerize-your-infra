# Deploy to:   modules/dns/kubernetes/Dockerfile
# Apply:       docker build --platform linux/arm64
# Module:      dns
# Requires:    none
#
# BIND9 image for the EKS arm64 nodes. The official ISC image is amd64-only.
# Parameters modified from baseline: Ubuntu 24.04 base, fixed uid/gid 101, non-root default user
#
# Note: bind9-dnsutils provides dig, used by the Pod probes and the validation steps.

FROM ubuntu:24.04

RUN groupadd --system --gid 101 bind \
 && useradd --system --uid 101 --gid bind --no-create-home --shell /usr/sbin/nologin bind \
 && apt-get update \
 && apt-get install -y --no-install-recommends bind9 bind9-utils bind9-dnsutils \
 && rm -rf /var/lib/apt/lists/*

USER bind

EXPOSE 5353/udp 5353/tcp

ENTRYPOINT ["/usr/sbin/named"]
CMD ["-g"]