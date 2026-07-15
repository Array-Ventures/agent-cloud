FROM oven/bun:slim

# Install Letta Code
# git: required at runtime for memory sync
# python3: required at runtime for skills (e.g. Discord)
# curl/wget: common in tool and skill examples for fetching remote assets/APIs
# jq: common in API/debug examples for inspecting JSON responses
# nodejs: required by the installed letta CLI entrypoint
# npm: fallback package manager for channel runtime installs and remote shell use.
# It is installed with Bun below instead of Debian's npm package to avoid
# pulling a large extra dependency tree into the runtime image.
ENV BUN_INSTALL_GLOBAL_DIR=/opt/letta-code
# The CLI is installed with Bun into /opt, so path-based package-manager
# detection would otherwise fall back to npm. Prefer Bun for channel runtime
# installs while still shipping npm as a compatibility fallback.
ENV LETTA_PACKAGE_MANAGER="bun"

# The GitHub workflow keeps this file at the latest published npm version.
# Railway services connected to this repo can then auto-deploy from Git commits
# instead of staying pinned to the version baked into the first build.
ARG LETTA_CODE_VERSION=""
COPY letta-code-version.txt /tmp/letta-code-version.txt

RUN set -eux; \
    apt-get update; \
    apt-get install -y git python3 curl wget jq make g++ unzip; \
    # Node 22 via NodeSource. Node 20 lacks webidl.markAsUncloneable, which the
    # undici bundled in node-gyp@latest requires to compile node-pty (a native
    # dependency of letta-code). On Node 20 the letta-code install fails with
    # "webidl.util.markAsUncloneable is not a function".
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y nodejs; \
    version="${LETTA_CODE_VERSION:-$(cat /tmp/letta-code-version.txt)}"; \
    bun install -g "@letta-ai/letta-code@${version}" "npm@10"; \
    apt-get purge -y make g++; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

# Pinned CLI versions (bumped automatically by Renovate — see renovate.json).
# renovate: datasource=github-releases depName=supabase/cli
ARG SUPABASE_VERSION=2.108.0
# renovate: datasource=npm depName=vercel
ARG VERCEL_VERSION=54.18.2

# Agent toolchain: GitHub, Supabase, and Vercel CLIs baked into the image.
# Runtime installs (e.g. via brew) land on the ephemeral overlay and are wiped
# on every container restart; baking them here makes them durable and keeps the
# small /root volume free. Auth/secrets for these stay out of the image and are
# provided at runtime (Letta /secret or env vars).
RUN set -eux; \
    # GitHub CLI (official apt repo)
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y gh; \
    rm -rf /var/lib/apt/lists/*; \
    # Supabase CLI (pinned release, SHA256-verified against the release checksums)
    arch="$(dpkg --print-architecture)"; \
    sb_base="https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}"; \
    sb_tar="supabase_${SUPABASE_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSL -o "/tmp/${sb_tar}" "${sb_base}/${sb_tar}"; \
    curl -fsSL -o /tmp/supabase_checksums.txt "${sb_base}/checksums.txt"; \
    (cd /tmp && grep " ${sb_tar}\$" supabase_checksums.txt | sha256sum -c -); \
    tar -xz -C /usr/local/bin -f "/tmp/${sb_tar}" supabase; \
    rm -f "/tmp/${sb_tar}" /tmp/supabase_checksums.txt; \
    # Vercel CLI (pinned, bun global -> same bin dir as letta, /usr/local/bin)
    bun install -g "vercel@${VERCEL_VERSION}"; \
    # agent-browser CLI (bun global -> on PATH so the agent uses `agent-browser`
    # directly instead of falling back to `npx agent-browser`, which re-resolves
    # every call and refills the volume). Chrome itself is downloaded at runtime
    # via `agent-browser install` into the /root volume (persists).
    bun install -g agent-browser; \
    # Composio CLI. Its installer drops the binary + helper files in
    # $HOME/.composio; redirect HOME to /opt so it lands OUTSIDE /root (the
    # volume mounts at /root and would otherwise mask it), then symlink onto
    # PATH. Runtime config/session still uses $HOME/.composio (=/root/.composio,
    # on the volume) so a one-time `composio login` persists across restarts.
    # NOTE: composio publishes no pinned binary URL; this curl|bash script is its
    # only supported install. Accepted as a TLS-trusted source (same installer
    # used on developer machines). Revisit if a versioned artifact is published.
    HOME=/opt COMPOSIO_INSTALL_PLUGINS=0 sh -c 'curl -fsSL https://composio.dev/install | bash'; \
    ln -sf /opt/.composio/composio /usr/local/bin/composio; \
    # sanity checks (fail the build if any CLI is missing from PATH)
    gh --version; supabase --version; vercel --version; composio --version; agent-browser --version

ENV ENV_NAME="cloud"
ENV LETTA_RESTORE_ENABLED_CHANNELS="1"
# Default agent-browser to the persistent profile saved in the workspace so
# logins/cookies are detected and reused (override per-command with --profile).
ENV AGENT_BROWSER_PROFILE="/root/workspace/.browser-profiles/array-workspace"

# Run the agent's shell work from a volume-backed dir so files persist across
# restarts. The volume mounts at /root, masking any build-time dir, so the
# workspace is created at runtime. ~/.letta state already persists via /root.
CMD ["sh", "-c", "mkdir -p /root/workspace && cd /root/workspace && rm -rf /root/.letta/channels/*/auth/*/.session-lock 2>/dev/null; letta server --env-name \"$ENV_NAME\" --channels whatsapp"]
