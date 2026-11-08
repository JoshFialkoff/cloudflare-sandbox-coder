# Sandbox SDK container image with Python 3, pip, google-ads, and bws CLI pre-installed.
#
# IMPORTANT: keep this version in sync with your @cloudflare/sandbox npm package.
FROM docker.io/cloudflare/sandbox:0.12.10

# Install Python 3, pip, venv, curl, and unzip.
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl unzip && \
    rm -rf /var/lib/apt/lists/*

# Create a virtualenv so pip works without --break-system-packages.
# The venv is added to PATH so `python3` and `pip` resolve to it.
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir google-ads

# Install Bitwarden Secrets Manager CLI (bws) from GitHub releases.
RUN BWS_URL=$(curl -sL https://api.github.com/repos/Bitwarden/sdk-secrets/releases/latest | \
    grep -o '"browser_download_url": *"[^"]*"' | \
    grep -i linux | grep -i x86_64 | grep -iv musl | head -1 | \
    sed 's/.*"browser_download_url": *"//;s/"//') && \
    curl -sL "$BWS_URL" -o /tmp/bws-download && \
    (cd /tmp && unzip -o bws-download 2>/dev/null || tar xzf bws-download 2>/dev/null || true) && \
    find /tmp -name 'bws' -type f -exec cp {} /usr/local/bin/bws \; && \
    chmod +x /usr/local/bin/bws && \
    rm -rf /tmp/bws-download /tmp/bws*

ENV PATH="/opt/venv/bin:$PATH"
