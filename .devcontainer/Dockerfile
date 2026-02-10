FROM mcr.microsoft.com/devcontainers/base:noble

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# System packages + firewall tools + R dependencies + Python
RUN apt-get update && apt-get install -y --no-install-recommends \
  git gh less procps sudo fzf zsh man-db unzip gnupg2 \
  jq nano vim \
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

# Node.js 20 via nodesource (base:noble may not include it)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Poetry via pipx (as vscode user later; install globally here)
RUN pipx install poetry --global

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

# Set DEVCONTAINER env var for detection in CLAUDE.md and scripts
ENV DEVCONTAINER=true

# Create workspace and config directories
RUN mkdir -p /workspace /home/vscode/.claude && \
  chown -R vscode:vscode /workspace /home/vscode/.claude

WORKDIR /workspace

# Copy firewall + env setup scripts
COPY init-firewall.sh /usr/local/bin/
COPY setup-env.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-env.sh && \
  echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall && \
  chmod 0440 /etc/sudoers.d/firewall
USER vscode

ENV HISTFILE=/commandhistory/.bash_history
ENV EDITOR=nano
ENV VISUAL=nano
