# DESIGNED FOR BUILDING ON AMD64 ONLY
#####################################
# Requires binfm_misc registration
# https://github.com/multiarch/qemu-user-static#binfmt_misc-register
ARG DOTNET_VERSION=10.0

FROM node:24-alpine as web-builder
ARG JELLYFIN_WEB_VERSION=master
RUN apk add curl git zlib zlib-dev autoconf g++ make libpng-dev gifsicle alpine-sdk automake libtool make gcc musl-dev nasm python3 \
 && curl -L https://github.com/jellyfin/jellyfin-web/archive/${JELLYFIN_WEB_VERSION}.tar.gz | tar zxf - \
 && apk del curl \
 && cd jellyfin-web-* \
 && npm ci --no-audit --unsafe-perm \
 && npm run build:production \
 && mv dist /dist

FROM debian:bookworm-slim as app

# https://askubuntu.com/questions/972516/debian-frontend-environment-variable
ARG DEBIAN_FRONTEND="noninteractive"
# http://stackoverflow.com/questions/48162574/ddg#49462622
ARG APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn
# https://github.com/NVIDIA/nvidia-docker/wiki/Installation-(Native-GPU-Support)
ENV NVIDIA_VISIBLE_DEVICES="all"
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# Same set as the official jellyfin-packaging docker image. CONFIG_DIR and LOG_DIR
# must be explicit: the server only skips its $XDG_CONFIG_HOME fallback when the
# config dir already exists or --datadir was given on the command line, so on a
# fresh volume it would otherwise resolve config to $HOME/.config/jellyfin.
ENV JELLYFIN_DATA_DIR=/config
ENV JELLYFIN_CACHE_DIR=/cache
ENV JELLYFIN_CONFIG_DIR=/config/config
ENV JELLYFIN_LOG_DIR=/config/log
ENV XDG_CACHE_HOME=/cache

# https://github.com/intel/compute-runtime/releases
ARG GMMLIB_VERSION=22.3.11.ci17757293
ARG IGC_VERSION=1.0.15136.22
ARG NEO_VERSION=23.39.27427.23
ARG LEVEL_ZERO_VERSION=1.3.27427.23

RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y ca-certificates gnupg curl \
 && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-jellyfin.gpg \
 && echo "deb [arch=$( dpkg --print-architecture )] https://repo.jellyfin.org/$( awk -F'=' '/^ID=/{ print $NF }' /etc/os-release ) $( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release ) main" | tee /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y mesa-va-drivers jellyfin-ffmpeg6 openssl locales \
# Intel VAAPI Tone mapping dependencies:
# Prefer NEO to Beignet since the latter one doesn't support Comet Lake or newer for now.
# Do not use the intel-opencl-icd package from repo since they will not build with RELEASE_WITH_REGKEYS enabled.
 && mkdir intel-compute-runtime \
 && cd intel-compute-runtime \
 && curl -LO https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-core_${IGC_VERSION}_amd64.deb \
         -LO https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-opencl_${IGC_VERSION}_amd64.deb \
         -LO https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-level-zero-gpu_${LEVEL_ZERO_VERSION}_amd64.deb \
         -LO https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-opencl-icd_${NEO_VERSION}_amd64.deb \
         -LO https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/libigdgmm12_${GMMLIB_VERSION}_amd64.deb \
 && dpkg -i *.deb \
 && cd .. \
 && rm -rf intel-compute-runtime \
 && apt-get remove gnupg -y \
 && apt-get clean autoclean -y \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && chmod 777 ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR} \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} as builder
WORKDIR /repo
COPY . .
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

RUN dotnet publish Jellyfin.Server --configuration Release --output="/jellyfin" --self-contained --runtime linux-x64 -p:DebugSymbols=false -p:DebugType=none

# ---- Plugin builder ----
# Compiles community plugins against the fork's local server source so they bind to
# the new 12.x ABI instead of stock 10.11.x. Source is reused from the builder stage.
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} as plugin-builder
WORKDIR /work
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /repo /repo
COPY scripts/build-plugins.sh /work/build-plugins.sh
RUN bash /work/build-plugins.sh

FROM app

ENV HEALTHCHECK_URL=http://localhost:8096/health

COPY --from=builder /jellyfin /jellyfin
COPY --from=web-builder /dist /jellyfin/jellyfin-web
COPY --from=plugin-builder /work/out /opt/jellyfin-bundled-plugins
COPY scripts/jellyfin-entrypoint.sh /jellyfin-entrypoint.sh
RUN chmod +x /jellyfin-entrypoint.sh

EXPOSE 8096
VOLUME ${JELLYFIN_DATA_DIR} ${JELLYFIN_CACHE_DIR}
ENTRYPOINT ["/jellyfin-entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
    CMD curl -Lk -fsS "${HEALTHCHECK_URL}" || exit 1
