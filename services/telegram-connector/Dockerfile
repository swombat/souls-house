# Build context: services/telegram-connector.
#   docker build -t <registry>/souls-house-comms-telegram services/telegram-connector
# Build and runtime use the same digest-pinned Trixie base.
FROM python:3.13-slim-trixie@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS build
ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /src
COPY requirements.txt ./
# Wheels only, every one pinned, no dependency resolution. pyaes (Telethon's
# pure-Python AES fallback) ships only as an sdist, so it is built with the
# pinned setuptools and no build isolation (which would fetch an unpinned one).
RUN python -m venv /venv \
 && /venv/bin/pip install --no-deps --only-binary=:all: setuptools==80.9.0 \
 && /venv/bin/pip install --no-deps --no-build-isolation --only-binary=:all: --no-binary=pyaes -r requirements.txt \
 && /venv/bin/pip check
COPY connector ./connector
COPY tests ./tests
# The connector's tests (fake Telegram, fake Rails, real TLS, real
# subprocesses) must pass in the image's own Python before it ships.
RUN /venv/bin/python -m unittest discover -s tests -t . \
 && rm -rf tests \
 && /venv/bin/python -m compileall -q connector /venv \
 && mkdir -p /out/data

FROM python:3.13-slim-trixie@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PATH=/venv/bin:/usr/local/bin:/usr/bin:/bin \
    COMMS_DATA_DIR=/data
COPY --from=build /venv /venv
COPY --from=build /src/connector /app/connector
COPY --from=build --chown=65532:65532 /out/data /data
WORKDIR /app
USER 65532:65532
VOLUME ["/data"]
EXPOSE 8443
ENTRYPOINT ["/venv/bin/python", "-m", "connector"]
