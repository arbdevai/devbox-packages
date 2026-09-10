ARG BASE_IMAGE=ghcr.io/termux/package-builder:latest
FROM ${BASE_IMAGE}
USER root
COPY scripts/prepare-sdk.sh /opt/devbox/prepare-sdk.sh
RUN bash /opt/devbox/prepare-sdk.sh
USER builder
