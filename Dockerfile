# Sandbox SDK container image with Python 3, pip, and google-ads pre-installed.
#
# The -python variant already ships Python 3.11 with pip and venv.
# IMPORTANT: keep this version in sync with your @cloudflare/sandbox npm package.
FROM docker.io/cloudflare/sandbox:0.12.10-python

# Pre-install the google-ads library so sandboxes can use it without
# a runtime pip install on every cold start.
RUN pip install --no-cache-dir google-ads
