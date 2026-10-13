# The question server and the web UI in one image, for a NAS on your own
# network. The image holds no questions: build the databases into the /data
# volume (see "Running on a NAS with Docker" in README.md, and
# docs/docker-plan.md). Needs BuildKit, Docker's default builder since 23.0.

# Kept in step with .claude/hooks/session-start.sh.
ARG FLUTTER_VERSION=3.47.6

# --- The Flutter web build ---------------------------------------------------
# Its output is the same on every CPU, so it runs on the building machine's
# own platform, even when the image is for another one.
# buildpack-deps already has what Flutter needs (git, curl, unzip, xz).
FROM --platform=$BUILDPLATFORM buildpack-deps:bookworm AS web
ARG FLUTTER_VERSION

# Flutter warns against running as root, so the build runs as a user of its
# own, which owns the SDK and the sources.
RUN useradd --create-home builder
USER builder
WORKDIR /home/builder

# No official Flutter image has this version, so clone it at its tag.
RUN git clone --quiet --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git flutter
ENV PATH=/home/builder/flutter/bin:$PATH
RUN flutter --disable-analytics > /dev/null && flutter precache --web

WORKDIR /home/builder/src
# Packages first, so a change to lib/ doesn't fetch them again.
COPY --chown=builder pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY --chown=builder . .
# --no-web-resources-cdn: load nothing from Google, so the page works on a
# network without internet access.
RUN flutter build web --no-web-resources-cdn

# --- The server ----------------------------------------------------------------
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY tool/serve_clues.py tool/build_clue_db.py tool/build_trivia_db.py tool/
COPY --from=web /home/builder/src/build/web web/

# The scripts default to data/ and assets/db/ under the repository root; both
# lead to the volume, so the databases, the downloads they're built from and
# reports.db all live there with no path flags.
RUN mkdir /data assets \
    && ln -s /data data \
    && ln -s /data assets/db \
    && chown 1000:1000 /data
VOLUME /data

USER 1000:1000
EXPOSE 8080

# /v1/info only answers when the database can be read.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python3", "-c", "import os, urllib.request as u; t = os.environ.get('QUIZ_TOKEN'); r = u.Request('http://127.0.0.1:8080/v1/info', headers={'Authorization': 'Bearer ' + t} if t else {}); u.build_opener(u.ProxyHandler({})).open(r, timeout=4)"]

CMD ["python3", "tool/serve_clues.py", "--host", "0.0.0.0", "--web", "web"]
