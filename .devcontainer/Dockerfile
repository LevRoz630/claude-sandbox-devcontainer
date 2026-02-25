FROM mcr.microsoft.com/devcontainers/base:noble

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# System packages, firewall, R, Python
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
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# 1Password CLI
RUN curl -fsSL https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
      > /etc/apt/sources.list.d/1password.list && \
    apt-get update && apt-get install -y 1password-cli && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 20
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Poetry, renv, Claude Code
RUN PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install poetry
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Git delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Bash history + directories
RUN mkdir -p /commandhistory && touch /commandhistory/.bash_history && chown -R vscode /commandhistory
RUN mkdir -p /workspace /home/vscode/.claude /home/vscode/.local/share/renv \
             /home/vscode/.config/gh /home/vscode/.config/op && \
  chown -R vscode:vscode /workspace /home/vscode/.claude /home/vscode/.local \
                         /home/vscode/.config/gh /home/vscode/.config/op

ENV DEVCONTAINER=true
ENV RENV_PATHS_CACHE=/home/vscode/.local/share/renv
ENV NODE_OPTIONS=--max-old-space-size=4096
ENV CLAUDE_CONFIG_DIR=/home/vscode/.claude

WORKDIR /workspace

# Scripts (strip CRLF for Windows working trees)
COPY init-firewall.sh setup-env.sh setup-1password.sh setup-credentials.sh sandbox-status.sh /usr/local/bin/
USER root
RUN sed -i 's/\r$//' /usr/local/bin/init-firewall.sh /usr/local/bin/setup-env.sh \
        /usr/local/bin/setup-1password.sh /usr/local/bin/setup-credentials.sh \
        /usr/local/bin/sandbox-status.sh && \
    chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-env.sh \
        /usr/local/bin/setup-1password.sh /usr/local/bin/setup-credentials.sh \
        /usr/local/bin/sandbox-status.sh && \
    printf '#!/bin/bash\nexec /usr/local/bin/setup-1password.sh --interactive "$@"\n' > /usr/local/bin/setup-1password && \
    printf '#!/bin/bash\nexec /usr/local/bin/sandbox-status.sh "$@"\n' > /usr/local/bin/sandbox-status && \
    chmod +x /usr/local/bin/setup-1password /usr/local/bin/sandbox-status

# Sudo: allowlist only (base image grants NOPASSWD:ALL)
RUN rm -f /etc/sudoers.d/vscode && \
    printf '%s\n' \
      "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /etc/init.d/ssh start" \
      "vscode ALL=(root) NOPASSWD: /usr/bin/chown -R vscode\:vscode /home/vscode/.config/op" \
    > /etc/sudoers.d/firewall && \
    chmod 0440 /etc/sudoers.d/firewall

USER vscode

ENV HISTFILE=/commandhistory/.bash_history
ENV EDITOR=nano
ENV VISUAL=nano

RUN echo "alias cc='claude --dangerously-skip-permissions'" >> /home/vscode/.bashrc
