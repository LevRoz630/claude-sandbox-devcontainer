FROM mcr.microsoft.com/devcontainers/base:noble

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# System packages + firewall tools + R dependencies + Python
RUN apt-get update && apt-get install -y --no-install-recommends \
  git gh less procps sudo fzf zsh man-db unzip gnupg2 \
  jq nano vim curl wget \
  # Firewall
  iptables ipset iproute2 dnsutils aggregate \
  # R base + compilation dependencies
  r-base r-base-dev \
  libcurl4-openssl-dev libssl-dev libxml2-dev \
  libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
  libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
  # Python
  python3 python3-venv python3-pip pipx \
  # SSH agent forwarding support
  socat \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 20 via nodesource APT repo (explicit GPG key, no curl|bash)
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Poetry via pipx into a shared location (available to all users)
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install poetry

# renv bootstrap
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Git delta for better diffs
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Persistent bash history
ARG USERNAME=vscode
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir -p /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Environment variables (defaults; devcontainer.json containerEnv can override)
ENV DEVCONTAINER=true
ENV RENV_PATHS_CACHE=/home/vscode/.local/share/renv
ENV NODE_OPTIONS=--max-old-space-size=4096
ENV CLAUDE_CONFIG_DIR=/home/vscode/.claude

# Create workspace, config, and cache directories
RUN mkdir -p /workspace /home/vscode/.claude /home/vscode/.local/share/renv \
             /home/vscode/.config/gh && \
  chown -R vscode:vscode /workspace /home/vscode/.claude /home/vscode/.local \
                         /home/vscode/.config/gh

WORKDIR /workspace

# Copy firewall + env setup scripts
# Strip CRLF: Windows working tree may have \r despite .gitattributes eol=lf
COPY init-firewall.sh /usr/local/bin/
COPY setup-env.sh /usr/local/bin/
USER root
RUN sed -i 's/\r$//' /usr/local/bin/init-firewall.sh /usr/local/bin/setup-env.sh && \
    chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-env.sh

# ============================================================================
# SECURITY: Lock down sudo
#
# The base image (devcontainers/base:noble) grants vscode NOPASSWD:ALL.
# We MUST remove that and restrict sudo to only the firewall init script.
# Without this, Claude can run `sudo iptables -F` and disable the firewall.
# ============================================================================
RUN rm -f /etc/sudoers.d/vscode && \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall && \
    chmod 0440 /etc/sudoers.d/firewall

USER vscode

ENV HISTFILE=/commandhistory/.bash_history
ENV EDITOR=nano
ENV VISUAL=nano
