FROM cloudflare/sandbox:0.8.0
RUN apt-get update && apt-get install -y --no-install-recommends git curl python3 python3-pip nodejs npm && rm -rf /var/lib/apt/lists/*
