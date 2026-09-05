# syntax=docker/dockerfile:1.7

FROM golang:1.26.8-bookworm

ARG TARGETARCH
ARG CODEX_VERSION=0.153.4
# Update these package digests together with CODEX_VERSION.
ARG CODEX_SHA256_AMD64=a822187e1a2420c61c5926721bfbd878701ed95547c9bb0d4de4498a16ba1821
ARG CODEX_SHA256_ARM64=fc395cb043a1093ab0db34f44aba3199bfaa9ce640cd9be7fd588f44b0da64a4

LABEL org.opencontainers.image.title="codex-ssh"
LABEL org.opencontainers.image.description="Remote SSH worker with Go, Git, and Codex CLI"
LABEL org.opencontainers.image.source="https://github.com/pmenglund/codex-ssh"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        less \
        openssh-client \
        openssh-server \
        procps \
        tar \
        tini \
        util-linux \
    && rm -f /etc/ssh/ssh_host_* \
    && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
    && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) codex_arch="x86_64"; codex_sha256="${CODEX_SHA256_AMD64}" ;; \
        arm64) codex_arch="aarch64"; codex_sha256="${CODEX_SHA256_ARM64}" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    codex_asset="codex-package-${codex_arch}-unknown-linux-musl"; \
    codex_url="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${codex_asset}.tar.gz"; \
    curl -fsSL "${codex_url}" -o /tmp/codex.tar.gz; \
    printf '%s  /tmp/codex.tar.gz\n' "${codex_sha256}" | sha256sum -c -; \
    mkdir -p /opt/codex; \
    tar -xzf /tmp/codex.tar.gz -C /opt/codex; \
    ln -s /opt/codex/bin/codex /usr/local/bin/codex; \
    rm -f /tmp/codex.tar.gz

RUN set -eux; \
    useradd --create-home --home-dir /home/codex --shell /bin/bash --uid 1000 codex; \
    mkdir -p /run/sshd /workspace /home/codex/.ssh /home/codex/.codex; \
    install -d -o root -g root -m 0700 /var/lib/sshd; \
    chown -R codex:codex /home/codex /workspace; \
    chmod 700 /home/codex/.ssh /home/codex/.codex; \
    { \
        echo "PermitRootLogin no"; \
        echo "PasswordAuthentication no"; \
        echo "KbdInteractiveAuthentication no"; \
        echo "ChallengeResponseAuthentication no"; \
        echo "PubkeyAuthentication yes"; \
        echo "AuthorizedKeysFile .ssh/authorized_keys"; \
        echo "AllowUsers codex"; \
        echo "HostKey /var/lib/sshd/ssh_host_ed25519_key"; \
        echo "X11Forwarding no"; \
        echo "PrintMotd no"; \
        echo "ClientAliveInterval 30"; \
        echo "ClientAliveCountMax 4"; \
        echo "SetEnv PATH=/home/codex/go/bin:/go/bin:${PATH} CODEX_HOME=/home/codex/.codex"; \
    } > /etc/ssh/sshd_config.d/codex.conf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/validate-authorized-keys.sh /usr/local/bin/validate-authorized-keys

RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/validate-authorized-keys

ENV CODEX_USER=codex WORKSPACE=/workspace

VOLUME ["/home/codex", "/workspace", "/var/lib/sshd"]

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
