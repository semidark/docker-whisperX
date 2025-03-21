# syntax=docker/dockerfile:1
ARG WHISPER_MODEL=base
ARG LANG=en
ARG UID=1001
ARG VERSION=EDGE
ARG RELEASE=0

# These ARGs are for caching stage builds in CI
# Leave them as is when building locally
ARG LOAD_WHISPER_STAGE=load_whisper
ARG NO_MODEL_STAGE=no_model
ARG LOAD_DIARIZATION_STAGE=load_diarization

ARG CACHE_HOME=/.cache
ARG CONFIG_HOME=/.config
ARG TORCH_HOME=${CACHE_HOME}/torch
ARG HF_HOME=${CACHE_HOME}/huggingface
# When downloading diarization model with auth token, it pyannote is not respecting the TORCH_HOME env variable.
# Instead it uses the PYANNOTE_CACHE environment variable, or "~/.cache/torch/pyannote" when it is unset.
# see https://github.com/pyannote/pyannote-audio/blob/240a7f3ef60bc613169df860b536b10e338dbf3c/pyannote/audio/core/pipeline.py#L71
ARG PYANNOTE_CACHE=${TORCH_HOME}/pyannote

########################################
# Base stage
########################################
FROM registry.access.redhat.com/ubi9/ubi-minimal AS base


## Todo: Use UBI 9 from local repo
# FROM redhat/ubi9-minimal AS base

# RUN \
#     # Apply latest updates; make sure to use internal RHEL 9 satellite repos only \
#     rm /etc/yum.repos.d/ubi.repo && \
#     microdnf repolist && \
#     microdnf update -y --nodocs --noplugins --disablerepo=* --enablerepo=rhel-9* --setopt install_weak_deps=0 && \
#     # Reinstall tzdata in order to switch timezone from the default UTC to the value provided with environment variable TZ
#     microdnf reinstall tzdata -y && \
#     # Cleanup caches
#     microdnf clean all

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

ENV PYTHON_VERSION=3.11
ENV PYTHONUNBUFFERED=1
ENV PYTHONIOENCODING=UTF-8

RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    microdnf -y upgrade --refresh --best --nodocs --noplugins --setopt=install_weak_deps=0 && \
    microdnf -y install --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
    python3.11
RUN ln -s /usr/bin/python3.11 /usr/bin/python3 && \
    ln -s /usr/bin/python3.11 /usr/bin/python

# Missing dependencies for arm64
# https://github.com/jim60105/docker-whisperX/issues/14
ARG TARGETPLATFORM
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
    microdnf -y install --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
    libgomp libsndfile; \
    fi

########################################
# Build stage
########################################
FROM base AS build

# RUN mount cache for multi-arch: https://github.com/docker/buildx/issues/549#issuecomment-1788297892
ARG TARGETARCH
ARG TARGETVARIANT

# Install build time requirements
RUN --mount=type=cache,id=dnf-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/var/cache/dnf \
    microdnf -y install --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
    git python3.11-pip findutils

WORKDIR /app

# Install under /root/.local
ARG PIP_USER="true"
ARG PIP_NO_WARN_SCRIPT_LOCATION=0
ARG PIP_ROOT_USER_ACTION="ignore"
ARG PIP_NO_COMPILE="true"
ARG PIP_NO_BINARY="all"
ARG PIP_DISABLE_PIP_VERSION_CHECK="true"

# Install requirements
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    pip3.11 install -U --force-reinstall pip setuptools wheel && \
    pip3.11 install -U --extra-index-url https://download.pytorch.org/whl/cu121 \
    torch==2.2.2 torchaudio==2.2.2 \
    pyannote.audio==3.1.1 \
    # https://github.com/jim60105/docker-whisperX/issues/40
    "numpy<2.0"

RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    --mount=source=whisperX/requirements.txt,target=requirements.txt \
    pip3.11 install -r requirements.txt

# Install whisperX
RUN --mount=type=cache,id=pip-$TARGETARCH$TARGETVARIANT,sharing=locked,target=/root/.cache/pip \
    --mount=source=whisperX,target=.,rw \
    --mount=type=tmpfs,target=/tmp \
    pip3.11 install . && \
    # Cleanup (Needed for Podman as it DOES write back to the build context)
    rm -rf build

# Test whisperX
RUN python3 -c 'import whisperx;'

########################################
# Final stage for no_model
########################################
FROM base AS no_model

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

ARG CACHE_HOME
ARG CONFIG_HOME
ARG TORCH_HOME
ARG HF_HOME
ENV XDG_CACHE_HOME=${CACHE_HOME}
ENV TORCH_HOME=${TORCH_HOME}
ENV HF_HOME=${HF_HOME}

ARG UID
RUN install -d -m 775 -o $UID -g 0 /licenses && \
    install -d -m 775 -o $UID -g 0 /root && \
    install -d -m 775 -o $UID -g 0 ${CACHE_HOME} && \
    install -d -m 775 -o $UID -g 0 ${CONFIG_HOME}

## TODO Think about building ffmpeg from source if needed
# ffmpeg
# https://github.com/wader/static-ffmpeg
COPY --from=mwader/static-ffmpeg:7.1 /ffmpeg /usr/local/bin/

## TODO Think about building dumb-init from source if needed
# https://github.com/Yelp/dumb-init
# https://github.com/building5/docker-dumb-init
COPY --from=building5/dumb-init:1.2.1 /dumb-init /usr/local/bin/

# Copy licenses (OpenShift Policy)
COPY --chown=$UID:0 --chmod=775 LICENSE /licenses/LICENSE
COPY --chown=$UID:0 --chmod=775 whisperX/LICENSE /licenses/whisperX.LICENSE

# Copy dependencies and code (and support arbitrary uid for OpenShift best practice)
# https://docs.openshift.com/container-platform/4.14/openshift_images/create-images.html#use-uid_create-images
COPY --chown=$UID:0 --chmod=775 --from=build /root/.local /root/.local

ENV PATH="/root/.local/bin:$PATH"
ENV PYTHONPATH="/root/.local/lib/python3.11/site-packages"

WORKDIR /app

VOLUME [ "/app" ]

USER $UID

STOPSIGNAL SIGINT

ENTRYPOINT [ "dumb-init", "--", "/bin/sh", "-c", "whisperx \"$@\"" ]

ARG VERSION
ARG RELEASE
LABEL name="jim60105/docker-whisperX" \
    # Authors for WhisperX
    vendor="Bain, Max and Huh, Jaesung and Han, Tengda and Zisserman, Andrew" \
    # Maintainer for this docker image
    maintainer="jim60105" \
    # Dockerfile source repository
    url="https://github.com/jim60105/docker-whisperX" \
    version=${VERSION} \
    # This should be a number, incremented with each change
    release=${RELEASE} \
    io.k8s.display-name="WhisperX" \
    summary="WhisperX: Time-Accurate Speech Transcription of Long-Form Audio" \
    description="This is the docker image for WhisperX: Automatic Speech Recognition with Word-Level Timestamps (and Speaker Diarization) from the community. For more information about this tool, please visit the following website: https://github.com/m-bain/whisperX."

########################################
# load_whisper stage
# This stage will be tagged for caching in CI.
########################################
FROM ${NO_MODEL_STAGE} AS load_whisper

ARG CONFIG_HOME
ARG XDG_CONFIG_HOME=${CONFIG_HOME}
ARG HOME="/root"

## TODO Think about using silero vad model
# Preload vad model
RUN python3 -c 'from whisperx.vads.pyannote import load_vad_model; load_vad_model("cpu");'

ARG WHISPER_MODEL
ENV WHISPER_MODEL=${WHISPER_MODEL}

# Preload fast-whisper
RUN echo "Preload whisper model: ${WHISPER_MODEL}" && \
    python3 -c "import faster_whisper; model = faster_whisper.WhisperModel('${WHISPER_MODEL}')"

########################################
# load_align stage
########################################
FROM ${LOAD_WHISPER_STAGE} AS load_align

ARG LANG
ENV LANG=${LANG}

# Preload align models
RUN --mount=source=load_align_model.py,target=load_align_model.py \
    for i in ${LANG}; do echo "Preload align model: $i"; python3 load_align_model.py "$i"; done


########################################
# load_diarization stage
########################################
FROM load_align AS load_diarization

ARG HOME="/root"
ARG PYANNOTE_CACHE
ENV PYANNOTE_CACHE=${PYANNOTE_CACHE}

ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}

# Preload align models
RUN --mount=source=load_diarization_model.py,target=load_diarization_model.py \
    echo "Preload pyannote/speaker-diarization-3.1 model with HF_TOKEN: ${HF_TOKEN:0:5}..."; python3 load_diarization_model.py "${HF_TOKEN}"


########################################
# Final stage with model
########################################
FROM ${NO_MODEL_STAGE} AS final

ARG UID

ARG CACHE_HOME
COPY --chown=$UID:0 --chmod=775 --from=load_diarization ${CACHE_HOME} ${CACHE_HOME}

ARG LANG
ENV LANG=${LANG}
ARG WHISPER_MODEL
ENV WHISPER_MODEL=${WHISPER_MODEL}

# Take the first language from LANG env variable
ENTRYPOINT [ "dumb-init", "--", "/bin/sh", "-c", "LANG=$(echo ${LANG} | cut -d ' ' -f1); whisperx --model \"${WHISPER_MODEL}\" --language \"${LANG}\" \"$@\"" ]

ARG VERSION
ARG RELEASE
LABEL version=${VERSION} \
    release=${RELEASE}
