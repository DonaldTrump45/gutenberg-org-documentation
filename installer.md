# Deploying `gutenberg-scraper` as a Linux Background Service

**This guide runs everything as `root`** — no dedicated service user, minimal systemd unit (no memory/CPU limits, no filesystem sandboxing).

**Assumption used throughout:** the repo lives at `/gutenberg-org-documentation` (a subfolder directly under `/`).

**Repo:** [`PrajwalKoirala638/gutenberg-org-documentation`](https://github.com/PrajwalKoirala638/gutenberg-org-documentation) — a Go program that walks Project Gutenberg ebook IDs sequentially and downloads each one's epub file for education/research/preservation purposes.

**Scope of this guide:** just the scraper service. Your own `uploader.sh` (which also handles PDF conversion) isn't covered here — wire it up as a second systemd unit however fits your script; this doc only needs to get the scraper itself running reliably.

---

## What this program actually does (read before deploying)

Worth knowing up front, since it shapes how the systemd unit gets written:

- **Stdlib only.** `main.go` imports nothing outside Go's standard library (`net/http`, `context`, `os`, etc.) — no third-party packages. `go mod download` has nothing to fetch.
- **No `go.mod` in the repo,** so `go build` will fail with a "no go.mod" error until you run `go mod init` yourself (Part 1, step 7).
- **It only ever writes to `Assets/<id>.epub`.** A `PDFs/` folder is created and used as a skip-check (if a same-named file exists there, the index is skipped), but the program never writes into it — so `PDFs/` will stay empty at this stage. (Sounds like your `uploader.sh` is what actually produces PDFs downstream — that's outside this program.)
- **No `CSVs/`, no `downloaded.txt`, no resume-checkpoint variable.** "Resuming" is implicit: it re-walks IDs `1` → `80000` on every run and skips whatever's already on disk.
- **The loop always restarts at ID `1`, and every iteration — skipped or not — pauses 2 seconds.** One full pass over the whole ID range takes roughly 44+ hours _in sleeps alone_, regardless of how much is already downloaded. This matters directly for the `RestartSec` choice in Part 2 — see the callout there.
- It exits on its own once `pageNumber` reaches `80000`, or on `SIGINT`/`SIGTERM` (handled cleanly via `signal.NotifyContext`).

---

# Part 1: Installing the Go Toolchain and the Repo

## 1. Detect your CPU architecture

```bash
ARCH=$(dpkg --print-architecture)
echo "Detected architecture: $ARCH"
```

Returns `amd64` or `arm64`. Go's official toolchain has native support for both — no ARM64 gap to work around.

---

## 2. Update the package index

```bash
apt-get update && apt-get upgrade -y
```

---

## 3. Install base system dependencies (including Go)

```bash
apt-get install -y ca-certificates curl git coreutils golang-go sudo bash calibre ghostscript qpdf
```

| Package           | Reason                                                                                                                                        |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `ca-certificates` | Root certificates so Go's HTTP client and `git` can validate HTTPS/TLS to `gutenberg.org` and GitHub.                                         |
| `curl`            | Manual connectivity checks against `gutenberg.org`/GitHub while troubleshooting; not required by any command below since Go comes from `apt`. |
| `git`             | Clones the repo (step 6). Also whatever your `uploader.sh` shells out to — set up its credentials separately.                                 |
| `coreutils`       | Basic utilities (`date`, `wc`, `tail`, `find`) — usually already present, installed explicitly as a guard.                                    |
| `golang-go`       | The Go toolchain — compiles the scraper.                                                                                                      |
| `sudo`            | Lets non-root invocations elevate if you need them later.                                                                                     |
| `bash`            | Shell used to run scripts (including your `uploader.sh`).                                                                                     |
| `calibre`         | An ebook management application that includes tools for converting ebooks between formats.                                                    |
| `ghostscript`     | A command-line tool for creating, converting, compressing, and optimizing PDF files.                                                          |
| `qpdf`            | A command-line tool for transforming and optimizing PDF files, including compression, encryption, and structural manipulation.                |

Nothing browser-related is needed — this is a plain HTTP client, no headless browser anywhere in the chain.

**Resolve actual binary paths — don't assume a fixed location:**

```bash
CURL_BIN=$(command -v curl)
GO_BIN=$(command -v go)
GIT_BIN=$(command -v git)
SUDO_BIN=$(command -v sudo)
BASH_BIN=$(command -v bash)

for var in CURL_BIN GO_BIN GIT_BIN SUDO_BIN BASH_BIN; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var not found on PATH — the install step for it failed or didn't complete."
  else
    echo "$var = ${!var}"
  fi
done

"$GO_BIN" version
```

`apt`'s `golang-go` tracks the Ubuntu release and can lag upstream — on Ubuntu 24.04 ("noble") you'll get Go 1.22.x, which is fine for this repo (stdlib-only, no exotic language features). On older Ubuntu you may get 1.18.x; that's still fine here too, since nothing in `main.go` needs a recent Go version — but if you ever add dependencies later, revisit this.

---

## 4. Verify available disk space

```bash
df -h /
```

The loop targets ebook IDs up to `80000`; most of those IDs won't exist on Gutenberg (a 404/"not found" page still costs a request+retry cycle before being skipped over — though note the retry/not-found-detection logic is currently commented out in `main.go`, so as shipped it'll attempt to download an epub for every single ID and just log a failure for the ones that don't exist, without stopping the loop). Budget disk space assuming a meaningful fraction of 80,000 epub files could land in `Assets/`, not just a small curated set.

---

## 5. Set the application directory

```bash
APP_DIR=/gutenberg-org-documentation
```

---

## 6. Clone the repository

```bash
"$GIT_BIN" clone https://github.com/PrajwalKoirala638/gutenberg-org-documentation.git "$APP_DIR"
```

---

## 7. Initialize the Go module and build the binary

**This repo has no `go.mod`**, so there's no `go mod download` step. Instead, initialize a module first:

```bash
cd "$APP_DIR"
"$GO_BIN" mod init gutenberg-scraper
```

(Safe to skip if a `go.mod` has since been added upstream — `go mod init` will simply refuse to overwrite an existing one.)

**Build a real binary, instead of `go run`-ning from source on every launch:**

```bash
"$GO_BIN" build -o "$APP_DIR/gutenberg-scraper" "$APP_DIR/main.go"
chmod +x "$APP_DIR/gutenberg-scraper"
echo "Build OK: $APP_DIR/gutenberg-scraper"
```

Why build once instead of `go run`:

- `go run` recompiles from scratch on every invocation — wasted CPU on every restart, and it means the box needs the full Go toolchain forever just to start the scraper.
- A prebuilt binary starts instantly and is exactly what `systemctl status`/`journalctl` are reporting on if something goes wrong.
- The binary sits at `$APP_DIR/gutenberg-scraper`, next to `main.go`, `Assets/`, and `PDFs/` — keep it out of whatever `uploader.sh` commits (add a `gutenberg-scraper` line to `.gitignore` if it isn't already covered).

```bash
grep -qxF 'gutenberg-scraper' "$APP_DIR/.gitignore" || echo 'gutenberg-scraper' >> "$APP_DIR/.gitignore"
```

---

## 8. Manual test run before wiring up systemd

**Always verify interactively before automating.**

```bash
cd "$APP_DIR"
"$APP_DIR/gutenberg-scraper"
```

- `cd "$APP_DIR"` — **required.** `main.go` writes to the relative paths `./Assets/` and `./PDFs/` (the latter only ever gets `MkdirAll`'d, not written into — see the note above). Running from the wrong directory causes "no such file" errors on those relative writes.
- No display server, no browser flags needed — plain HTTP scraper.

Let it run for a minute or two and confirm files are actually appearing in `Assets/`, not `PDFs/`:

```bash
find "$APP_DIR/Assets" -name "*.epub" | wc -l
```

Stop it with `Ctrl+C` — `main.go` listens for `SIGINT` and shuts down cleanly at the current index rather than mid-write, so this is safe to interrupt.

**On resuming:** there's no checkpoint variable to set. Every run — including every systemd restart — starts counting from ID `1` again and skips ahead quickly past IDs it already has an `Assets/<id>.epub` (or `PDFs/<id>.pdf`, if your uploader ever writes there) for. The **2-second delay between requests still applies on every skipped index**, though, so re-reaching wherever you left off after a restart isn't instantaneous — see the `RestartSec` note in Part 2.

---

# Part 2: The systemd Service

`main.go` runs to completion (ID `80000`) or until interrupted, then exits — so `Restart=always` + `RestartSec` turns that into a recurring, self-healing job.

**On `RestartSec` specifically:** because the loop always restarts at ID `1` and every index — hit or skip — costs a 2-second sleep, a full walk back to "new ground" after a restart takes roughly the same ~44 hours whether `RestartSec` is 5 seconds or 5 minutes. The setting isn't meaningfully trading off resume speed here; it's only a courtesy delay before that walk begins (and a brake against rapid restart-loops if the binary is crashing immediately, e.g. a bad build). A short value like `30`–`60` seconds is reasonable, since one full pass already takes days regardless.

```bash
tee /etc/systemd/system/gutenberg-scraper.service > /dev/null <<EOF
[Unit]
Description=Project Gutenberg Ebook Scraper (gutenberg-org-documentation)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/gutenberg-scraper
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gutenberg-scraper

[Install]
WantedBy=multi-user.target
EOF
```

| Directive                                 | Why it's set this way                                                                                                 |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `After=`/`Wants=network-online.target`    | Don't start before the network is usable.                                                                             |
| `Type=simple`                             | The process in `ExecStart` _is_ the main process.                                                                     |
| _(no `User=`/`Group=`)_                   | Runs as `root`, systemd's default — the deliberate simplification for this deployment.                                |
| `WorkingDirectory=`                       | The binary writes to the relative path `./Assets/` — must point at the repo root.                                     |
| `ExecStart=`                              | Points directly at the prebuilt `$APP_DIR/gutenberg-scraper` binary from step 7 — no Go toolchain needed at run time. |
| `Restart=always` + `RestartSec=30`        | Restarts after the binary exits (finishes the ID range, or crashes) or is killed. See the reasoning above.            |
| `StandardOutput=`/`StandardError=journal` | Logs go to `journalctl` — filterable, timestamped, rotated automatically.                                             |
| `SyslogIdentifier=`                       | Tags log lines for `journalctl -t gutenberg-scraper`.                                                                 |
| `WantedBy=multi-user.target`              | Starts automatically at boot.                                                                                         |

Since PDF conversion lives in your uploader rather than in `main.go`, that's also the point where `Assets/*.epub` becomes `PDFs/*.pdf` — the scraper unit above has no opinion on that step.

---

## 9. The uploader service — already a daemon, no restart delay needed

Since your `uploader.sh` loops forever internally (its own `while true` + sleep), this unit is the opposite of the scraper's: `RestartSec` here is purely a crash safety net, not a scheduling mechanism.

**Placeholders to fill in below:** `$UPLOADER_PATH` — wherever your script actually lives (copy it into `$APP_DIR` first if it isn't there already, since `WorkingDirectory` needs to match wherever it expects to run relative paths from).

```bash
UPLOADER_PATH="$APP_DIR/uploader.sh"   # adjust if yours lives elsewhere

tee /etc/systemd/system/gutenberg-uploader.service > /dev/null <<EOF
[Unit]
Description=gutenberg-org-documentation Uploader (git sync + PDF conversion)
After=network-online.target gutenberg-scraper.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$SUDO_BIN $BASH_BIN $UPLOADER_PATH
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=gutenberg-uploader

[Install]
WantedBy=multi-user.target
EOF
```

| Directive                          | Why it's set this way                                                                                                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `After=gutenberg-scraper.service`  | Ordering only, not a hard dependency — the uploader can safely start before the scraper has produced anything, it'll just find nothing to convert/commit yet.       |
| `WorkingDirectory=`                | Set to `$APP_DIR` assuming your script operates on the repo's `git`/`Assets`/`PDFs` paths relative to the repo root — adjust if your script expects something else. |
| `ExecStart=`                       | Runs the script directly with `bash`; it's already self-looping, so nothing wraps it in a scheduling mechanism.                                                     |
| `Restart=always` + `RestartSec=30` | Only fires if the script itself crashes (e.g. an unhandled `git` or conversion failure) — not part of normal operation.                                             |
| `SyslogIdentifier=`                | Tags log lines for `journalctl -t gutenberg-uploader`.                                                                                                              |

If your script needs `git` push credentials for the account it commits as (SSH deploy key or a stored HTTPS credential/PAT for `root`), set those up before starting this unit, since a push auth failure will just get logged and retried on the script's own internal cycle rather than surfacing as a systemd failure.

---

## 10. Reload systemd and start both services

```bash
systemctl daemon-reload
systemctl enable --now gutenberg-scraper.service
systemctl enable --now gutenberg-uploader.service
```

---

## 11. Verifying it's actually working

```bash
systemctl start gutenberg-scraper.service
systemctl stop gutenberg-scraper.service
systemctl restart gutenberg-scraper.service
systemctl status gutenberg-scraper.service
journalctl -u gutenberg-scraper.service -f


systemctl start gutenberg-uploader.service
systemctl stop gutenberg-uploader.service
systemctl restart gutenberg-uploader.service
systemctl status gutenberg-uploader.service
journalctl -u gutenberg-uploader.service -f

watch -n 30 'find /gutenberg-org-documentation/Assets -name "*.epub" | wc -l'
```

---

## 12. Production monitoring

**Log rotation:** `journalctl --disk-usage` periodically; cap with `SystemMaxUse=500M` under `[Journal]` in `/etc/systemd/journald.conf` if needed.

**Disk space alerting**, since `Assets/` grows unbounded as the loop covers more of the ID range:

```bash
# /etc/cron.d/disk-space-check
0 * * * * root df / | awk 'NR==2 && $5+0 > 85 {print "Disk usage high: "$5}' | logger -t disk-check
```

**Keeping Go current:** `apt-get upgrade golang-go`, same as any other system package — you'll need to re-run step 7's build afterward to pick up the new toolchain.

---

## 13. Troubleshooting

| Symptom                                                                             | Likely cause / fix                                                                                                                                                                                                                                  |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `go build` fails with "go.mod file not found"                                       | Expected on a fresh clone — this repo doesn't ship one. Run `go mod init gutenberg-scraper` in `$APP_DIR` first (step 7), then rebuild.                                                                                                             |
| `systemctl start gutenberg-scraper.service` fails with "No such file or directory"  | The binary at `$APP_DIR/gutenberg-scraper` was never built — re-run step 7 and confirm `ls -la $APP_DIR/gutenberg-scraper` shows an executable file.                                                                                                |
| Scraper writes nothing to `Assets/`                                                 | Check `WorkingDirectory=` matches `$APP_DIR` exactly.                                                                                                                                                                                               |
| `PDFs/` stays empty and you expected PDFs                                           | Expected from the scraper alone — `main.go` never writes there; check the uploader unit is actually running (`systemctl status gutenberg-uploader.service`) and its conversion step is succeeding.                                                  |
| Service keeps "finishing" and restarting every ~44 hours                            | Expected behavior — one full pass over IDs `1`–`80000` at 2s/index takes that long; `Restart=always` just starts the next pass.                                                                                                                     |
| Journal fills with retry/backoff log lines for the same index                       | The not-found detection (`notFoundPhrase` check) is currently commented out in `main.go`, so a genuinely missing ebook ID isn't distinguished from a transient failure — every ID gets the full retry treatment before being logged as given-up-on. |
| `systemctl start gutenberg-uploader.service` fails with "No such file or directory" | `$UPLOADER_PATH` in the unit file doesn't point at your actual script — confirm the path and re-run `daemon-reload` after fixing it.                                                                                                                |
| Uploader logs a git push/auth failure repeatedly                                    | Check `git` credentials for whichever user the script runs as (expired PAT, revoked SSH key) — the script's internal retry will keep trying regardless.                                                                                             |
