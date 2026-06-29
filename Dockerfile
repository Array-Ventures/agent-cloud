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
    apt-get install -y git python3 curl wget jq nodejs make g++ unzip; \
    version="${LETTA_CODE_VERSION:-$(cat /tmp/letta-code-version.txt)}"; \
    bun install -g "@letta-ai/letta-code@${version}" "npm@10"; \
    apt-get purge -y make g++; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

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
    # Supabase CLI (release tarball -> /usr/local/bin)
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/supabase/cli/releases/latest/download/supabase_linux_${arch}.tar.gz" \
      | tar -xz -C /usr/local/bin supabase; \
    # Vercel CLI (bun global -> same bin dir as letta, /usr/local/bin)
    bun install -g vercel; \
    # Composio CLI. Its installer drops the binary + helper files in
    # $HOME/.composio; redirect HOME to /opt so it lands OUTSIDE /root (the
    # volume mounts at /root and would otherwise mask it), then symlink onto
    # PATH. Runtime config/session still uses $HOME/.composio (=/root/.composio,
    # on the volume) so a one-time `composio login` persists across restarts.
    HOME=/opt sh -c 'curl -fsSL https://composio.dev/install | bash'; \
    ln -sf /opt/.composio/composio /usr/local/bin/composio; \
    # sanity checks (fail the build if any CLI is missing from PATH)
    gh --version; supabase --version; vercel --version; composio --version

ENV ENV_NAME="cloud"
ENV LETTA_RESTORE_ENABLED_CHANNELS="1"

# Run the agent's shell work from a volume-backed dir so files persist across
# restarts. The volume mounts at /root, masking any build-time dir, so the
# workspace is created at runtime. ~/.letta state already persists via /root.
CMD ["sh", "-c", "mkdir -p /root/workspace && cd /root/workspace && letta server --env-name \"$ENV_NAME\" --debug"]
