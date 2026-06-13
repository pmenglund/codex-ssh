# syntax=docker/dockerfile:1.7

FROM golang:1.26.4-bookworm

ARG TARGETARCH
ARG CODEX_VERSION=0.139.0

LABEL org.opencontainers.image.title="codex-ssh"
LABEL org.opencontainers.image.description="Remote SSH worker with Go, Git, and Codex CLI"
LABEL org.opencontainers.image.source="https://github.com/pmenglund/codex-ssh"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENV CODEX_USER=codex
ENV CODEX_HOME=/home/codex
ENV WORKSPACE=/workspace
ENV PATH=/home/codex/go/bin:/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
    && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
    && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) codex_arch="x86_64" ;; \
        arm64) codex_arch="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    codex_asset="codex-${codex_arch}-unknown-linux-musl"; \
    codex_url="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/${codex_asset}.tar.gz"; \
    curl -fsSL "${codex_url}" -o /tmp/codex.tar.gz; \
    tar -xzf /tmp/codex.tar.gz -C /tmp; \
    install -m 0755 "/tmp/${codex_asset}" /usr/local/bin/codex; \
    rm -f /tmp/codex.tar.gz "/tmp/${codex_asset}"

RUN set -eux; \
    useradd --create-home --home-dir "${CODEX_HOME}" --shell /bin/bash --uid 1000 "${CODEX_USER}"; \
    mkdir -p /run/sshd "${WORKSPACE}" "${CODEX_HOME}/.ssh" "${CODEX_HOME}/.codex"; \
    chown -R "${CODEX_USER}:${CODEX_USER}" "${CODEX_HOME}" "${WORKSPACE}"; \
    chmod 700 "${CODEX_HOME}/.ssh"; \
    { \
        echo "PermitRootLogin no"; \
        echo "PasswordAuthentication no"; \
        echo "KbdInteractiveAuthentication no"; \
        echo "ChallengeResponseAuthentication no"; \
        echo "PubkeyAuthentication yes"; \
        echo "AuthorizedKeysFile .ssh/authorized_keys"; \
        echo "AllowUsers ${CODEX_USER}"; \
        echo "X11Forwarding no"; \
        echo "PrintMotd no"; \
        echo "ClientAliveInterval 30"; \
        echo "ClientAliveCountMax 4"; \
        echo "SetEnv PATH=${PATH}"; \
    } > /etc/ssh/sshd_config.d/codex.conf

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

VOLUME ["/home/codex", "/workspace"]

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
