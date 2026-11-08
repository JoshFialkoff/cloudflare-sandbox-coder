# Sandbox SDK container image with Python 3, pip, google-ads, and bws CLI pre-installed.
#
# IMPORTANT: keep this version in sync with your @cloudflare/sandbox npm package.
FROM docker.io/cloudflare/sandbox:0.12.10

# Install Python 3, pip, venv, and unzip (for bws CLI download).
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv unzip && \
    rm -rf /var/lib/apt/lists/*

# Create a virtualenv so pip works without --break-system-packages.
# The venv is added to PATH so `python3` and `pip` resolve to it.
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir google-ads

# Install Bitwarden Secrets Manager CLI (bws).
ARG BWS_VERSION=2.1.0
RUN curl -fsSL -o /tmp/bws.zip \
    "https://github.com/bitwarden/sdk-sm/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" && \
    unzip -o /tmp/bws.zip -d /tmp/bws-unpack && \
    install -m 0755 /tmp/bws-unpack/bws /usr/local/bin/bws && \
    rm -rf /tmp/bws.zip /tmp/bws-unpack && \
    bws --version

ENV PATH="/opt/venv/bin:$PATH"
