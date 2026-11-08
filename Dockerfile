# Sandbox SDK container image with Python 3, pip, and google-ads pre-installed.
#
# IMPORTANT: keep this version in sync with your @cloudflare/sandbox npm package.
FROM docker.io/cloudflare/sandbox:0.12.10

# Install Python 3, pip, and venv (the base 0.12.10 image does not include them).
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Create a virtualenv so pip works without --break-system-packages.
# The venv is added to PATH so `python3` and `pip` resolve to it.
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir google-ads

ENV PATH="/opt/venv/bin:$PATH"
