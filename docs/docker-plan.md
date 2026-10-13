# Plan: Run the server in a Docker container

`serve_clues.py --web` already serves the questions and the web UI to every
device on your network (see the [web UI plan](web-ui-plan.md)). What it
doesn't do is run unattended: today it needs a computer with Python, a
Flutter toolchain for the web build, the databases built in the repository
and a terminal left open. This plan packages the server and the web UI into
one Docker image, meant to run on a **NAS on your home network**, reachable
only by you: on the LAN directly, and from elsewhere through the Tailscale
already installed on the NAS.

That keeps within the clue dataset's terms (personal use, never the public
internet), so the container serves the Jeopardy! clues as well as trivia.

**Status:** done, in the three commits of §8. Where the code differs from
this plan:

- The build stage starts from `buildpack-deps:bookworm`, not
  `debian:bookworm-slim` plus `apt-get` (§2). It's an official image that
  already has git, curl, unzip and xz, so the build doesn't depend on a
  Debian mirror; it only runs on the building machine.
- The reports error (§4) names the resolved path, `/data/reports.db`, not
  `/app/data/reports.db`, so it matches the folder a person looks at.

Checked in this environment (linux/amd64, Docker 29.8, Compose 5.6) with the
image built from the Dockerfile as committed: `build_clue_db.py` in the
container downloaded the v42 dataset and wrote the 543,912-clue database
into the volume in 15 seconds; `docker compose up -d` reported healthy; the
API refused requests without the token and answered with it, while the page
loaded without it; `docker compose stop` took 0.2 seconds; a hidden clue was
still hidden after `down` and `up`; a volume the container can't write to
stopped it with the reports error; `QUIZ_DB=/data/trivia.db` served trivia;
and in Chromium the page asked for the token, showed a clue, flipped it and
scored Got it. Not checked: `build_trivia_db.py`'s 12-minute download in
the container (its database was built from the saved OpenTDB responses
instead), an ARM build, and `tailscale serve`.

## 0. What a person can do

- **Start it with one command** on the NAS, `docker compose up -d`, and play
  at `http://<nas>:8080/` from any browser on the LAN. It starts again after
  a reboot.
- **Play from anywhere** at `https://<nas>.<tailnet>.ts.net/` by running
  `tailscale serve --bg 8080` once on the NAS. The address has a real
  certificate, so release phone builds can use it as `QUESTION_API_URL`.
- **Build the databases on the NAS** with the same image, with nothing else
  installed there: `docker compose run --rm quizapp python3
  tool/build_clue_db.py` (or `build_trivia_db.py`).
- **Pick clues or trivia** with one setting, `QUIZ_DB` in `.env`.
- **Keep hidden questions** across restarts, upgrades and a recreated
  container: `reports.db` lives on the NAS, next to the databases.
- **Upgrade** with `git pull` and `docker compose up -d --build`.

## 1. What the code already does

| Code | What the container needs from it |
|---|---|
| `tool/serve_clues.py` | Serves the API and, with `--web`, the app. Standard library only, one process, threaded, logs to stdout and stderr. |
| `serve_clues.py --token` | Guards the API but not the app's files, and the page asks for the token (web UI plan §4). |
| `flutter build web --no-web-resources-cdn` | A web build that loads nothing from Google, so it works with no internet access. It needs no settings: it reads from the server that served it. |
| `pubspec.yaml` `platforms:` on `assets/db/` | Keeps the databases out of the web build. |
| `build_clue_db.py`, `build_trivia_db.py` | Standard library only, so they run in the same slim Python image. Their defaults write to `data/` and `assets/db/` under the repository root. |
| `GET /v1/info` | Answers only when the database is readable, so it makes a good health check. |

So the work is packaging, plus three small server changes (§4).

## 2. The image (`Dockerfile`)

Two stages:

1. **`web`**, the Flutter build. There is no official Flutter image, and the
   community `ghcr.io/cirruslabs/flutter` image stops at 3.44.0, so the
   stage clones Flutter at 3.47.6 onto `buildpack-deps:bookworm`, as the
   session hook does (`FLUTTER_VERSION`, kept in step with
   `.claude/hooks/session-start.sh`). It copies `pubspec.yaml` and
   `pubspec.lock` first and runs `flutter pub get`, so changes to `lib/`
   don't fetch packages again, then runs `flutter build web
   --no-web-resources-cdn`. It runs on `$BUILDPLATFORM`: the output is
   JavaScript and WebAssembly, the same on every CPU, so an image for an ARM
   NAS doesn't have to build Flutter under emulation.
2. **The runtime**, `python:3.13-slim`, with `serve_clues.py`,
   `build_clue_db.py`, `build_trivia_db.py` and the web build:

   ```
   /app/tool/*.py
   /app/web/            the Flutter web build
   /app/data      -> /data
   /app/assets/db -> /data
   /data/               the volume: clues.db, trivia.db, reports.db, downloads
   ```

   The two links put the scripts' defaults in the volume, so
   `build_clue_db.py` with no flags downloads into `/data` and writes
   `/data/clues.db`, and `serve_clues.py` reads it and keeps `reports.db`
   beside it. Nothing needs a path flag.

   It runs as an unprivileged user (uid and gid 1000), listens on 8080 and
   runs `python3 tool/serve_clues.py --host 0.0.0.0 --web web`. A
   `HEALTHCHECK` asks for `/v1/info`, with the token if one is set.

## 3. No questions in the image

The image holds the app and the scripts, never a database:
`.dockerignore` leaves out `data/`, `assets/db/`, `build/` and
`config/question_source.json`, so nothing built locally reaches the build
context, and the web build couldn't carry the databases anyway (§1). The
databases are built into, or copied onto, the volume on the NAS. A copy of
the image therefore says nothing about the dataset, though there's no
reason to publish it either.

## 4. Changes to `serve_clues.py`

- **Stop on SIGTERM.** `docker stop` sends SIGTERM. The server only handles
  Ctrl-C (`KeyboardInterrupt`), and as process 1 in a container a signal
  with no handler is ignored, so every stop waits 10 seconds and ends in
  SIGKILL. A SIGTERM handler that raises `KeyboardInterrupt` reuses the
  existing clean shutdown.
- **Settings from the environment.** `--db` and `--token` default to
  `QUIZ_DB` and `QUIZ_TOKEN` when they're set. A token in the container's
  command line shows in `docker inspect` and `ps`, and an environment
  variable can come from `.env`, which stays out of git. Flags still win.
- **Say why `reports.db` can't be opened.** On a NAS the volume is often
  owned by a user other than the container's, and creating the reports
  folder raises an uncaught `PermissionError` today. `main()` reports the
  path and the error and returns 1, as it does for a missing database.

The "personal use only" notice still prints on every start, since the
container listens on `0.0.0.0`. That's accurate, so it stays.

## 5. `compose.yaml` and `.env`

```yaml
services:
  quizapp:
    build: .
    image: quizapp
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./data:/data
    environment:
      QUIZ_DB: ${QUIZ_DB:-/data/clues.db}
      QUIZ_TOKEN: ${QUIZ_TOKEN:-}
```

- `QUIZ_DB` (`/data/trivia.db` for trivia) and `QUIZ_TOKEN` go in `.env`
  next to `compose.yaml`, which Compose reads by itself. `.env` is added
  to `.gitignore`, and `.env.example` documents both. An empty
  `QUIZ_TOKEN` means no token. (`env_file` with `required: false` would
  do the same, but needs a newer Compose than some NAS packages ship.)
- `user:` is left commented with a note: set it to the owner of `./data` on
  the NAS (`id -u`, `id -g`) if that isn't 1000.
- `ports` publishes on every interface, so LAN devices can connect; the
  NAS's firewall and router keep it off the internet, as for any LAN
  service.

## 6. Tailscale

Tailscale is already on the NAS, so the container doesn't need it.
`tailscale serve --bg 8080` on the NAS forwards
`https://<nas>.<tailnet>.ts.net` to the published port. That's the setup the
README already recommends for release builds, now pointed at the
container. A Tailscale sidecar container would only be needed on a host
without Tailscale, so it isn't part of this plan.

## 7. Tests

| Test | What it covers |
|---|---|
| `tool/test_serve_clues.py` | `QUIZ_DB` and `QUIZ_TOKEN` are used when set and flags win over them; an unwritable reports folder makes `main()` return 1 with a message; SIGTERM stops a running server cleanly (in a subprocess). |
| By hand, in this environment | `docker build`; the container starts as uid 1000 and reports healthy; the API answers with and without the token; `docker stop` takes well under 10 seconds; hidden questions survive a recreated container; `build_trivia_db.py` and `build_clue_db.py` write into the volume; the web UI loads and plays in Chromium. |

## 8. Suggested commit order

1. This plan.
2. `serve_clues.py`: SIGTERM, `QUIZ_DB` and `QUIZ_TOKEN`, the reports
   error, with tests.
3. `Dockerfile`, `.dockerignore`, `compose.yaml`, `.env.example`, `.env`
   in `.gitignore`, and a README section, "Running on a NAS with Docker".

## 9. Out of scope

- **Publishing the image** to a registry, and CI that builds it. It's
  built on the NAS (or another computer, §10) from the repository.
- **TLS in the container.** Tailscale provides it (§6).
- **Clues and trivia from one server.** A server holds one database, so
  playing both means two containers on two ports. Serving several would
  change `/v1/info` and the app's source list; that's its own plan.
- **CORS**, for hosting the page somewhere other than the server (web UI
  plan §12).

## 10. Risks and open questions

- **Building on the NAS.** The Flutter stage downloads about 1.5 GB and
  takes several minutes; a small NAS may be slow or short of memory. The
  image can be built on another computer instead (`docker buildx build
  --platform linux/arm64` for an ARM NAS) and moved with `docker save` and
  `docker load`. The final image is small (the Python base plus a 40 MB web
  build).
- **ARM.** The runtime image is multi-architecture and the Flutter stage
  runs on the build machine's CPU (§2), but only `linux/amd64` can be
  checked in this environment.
- **Volume ownership.** NAS bind mounts are often owned by the NAS user
  (uid 1026 on Synology, for example). §4 makes the failure clear and §5
  says how to fix it.
- **The token is a light guard**, as before. On a LAN plus a tailnet that
  only you can reach, it mainly keeps other people's devices on your
  network from playing your game.
