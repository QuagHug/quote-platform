# syntax=docker/dockerfile:1
# Toolbox: every CLI the scripts need, so the reviewer installs nothing locally.
FROM hashicorp/terraform:1.16.5 AS terraform
FROM grafana/k6:2.3.0 AS k6

# alpine/k8s ships kubectl, helm, jq, yq, kubeconform, curl, git.
FROM alpine/k8s:1.36.5
ARG TARGETARCH
ARG K3D_VERSION=v5.9.0
RUN set -eux; \
    base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"; \
    curl -fsSLo /tmp/k3d "${base}/k3d-linux-${TARGETARCH}"; \
    curl -fsSLo /tmp/checksums.txt "${base}/checksums.txt"; \
    want="$(grep " _dist/k3d-linux-${TARGETARCH}\$" /tmp/checksums.txt | cut -d' ' -f1)"; \
    echo "${want}  /tmp/k3d" | sha256sum -c -; \
    install -m 0755 /tmp/k3d /usr/local/bin/k3d; rm -f /tmp/k3d /tmp/checksums.txt
COPY --from=terraform /bin/terraform /usr/local/bin/terraform
COPY --from=k6 /usr/bin/k6 /usr/local/bin/k6
ENV IN_TOOLBOX=1
WORKDIR /workspace
