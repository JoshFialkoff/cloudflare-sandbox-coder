# Sandbox SDK container image with Python 3, pip, and google-ads pre-installed.
#
# IMPORTANT: keep this version in sync with your @cloudflare/sandbox npm package.
FROM docker.io/cloudflare/sandbox:0.12.10

# Install Python 3 and pip (the base 0.12.10 image does not include them).
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Pre-install the google-ads library so sandboxes can use it without
# a runtime pip install on every cold start.
RUN python3 -m pip install --no-cache-dir --break-system-packages google-ads
