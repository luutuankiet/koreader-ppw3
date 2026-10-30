# KOReader emulator shaped like a Kindle Paperwhite 3: the official Linux x86_64
# release under Xvfb, installed at the Kindle's paths, with koreader_mcp preinstalled.
# Build context is the repo root (see docker-compose.yml).
FROM ubuntu:24.04
ARG KOREADER_VERSION=v2026.07.1
ENV DEBIAN_FRONTEND=noninteractive

# xvfb + x11-apps/imagemagick: headless screen and a manual screenshot path.
# procps/psmisc/net-tools/iproute2: ps, killall, netstat, ss for the gateway's shell commands.
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11-utils x11-apps imagemagick \
      ca-certificates curl xz-utils locales fonts-dejavu-core \
      procps psmisc net-tools iproute2 \
      libgl1 libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 libxkbcommon0 libdbus-1-3 \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

# The release tarball ships the app under lib/koreader; put it where the Kindle has it.
RUN curl -fsSL -o /tmp/ko.tar.xz \
      https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/koreader-linux-x86_64-${KOREADER_VERSION}.tar.xz \
 && mkdir -p /tmp/ko /mnt/us \
 && tar -xf /tmp/ko.tar.xz -C /tmp/ko \
 && mv /tmp/ko/lib/koreader /mnt/us/koreader \
 && rm -rf /tmp/ko /tmp/ko.tar.xz \
 && mv /mnt/us/koreader/koreader.sh /mnt/us/koreader/koreader.sh.orig

COPY emulator/koreader-shim.sh /mnt/us/koreader/koreader.sh
COPY emulator/supervisor.sh /usr/local/bin/supervisor.sh
COPY emulator/seed/ /opt/emulator-seed/
COPY koreader_mcp.koplugin/ /mnt/us/koreader/plugins/koreader_mcp.koplugin/

# uid 1000 (the stock "ubuntu" user) so bind-mounted state and books stay editable on the host.
RUN chmod +x /mnt/us/koreader/koreader.sh /usr/local/bin/supervisor.sh \
 && mkdir -p /mnt/us/documents /mnt/us/koreader-home \
 && mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix \
 && chown -R 1000:1000 /mnt/us

ENV LC_ALL=en_US.UTF-8 \
    DISPLAY=:73 \
    SDL_VIDEODRIVER=x11 \
    KO_HOME=/mnt/us/koreader-home \
    EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 \
    MCP_LIVE_MODE=always MCP_DEVICE_NAME=emu MCP_GATEWAY_HOST=127.0.0.1 MCP_GATEWAY_DEVICE_PORT=9990

USER 1000:1000
WORKDIR /mnt/us/koreader
ENTRYPOINT ["/usr/local/bin/supervisor.sh"]
