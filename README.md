# cloud_mcp — Technical Documentation

## Table of Contents

1. [What This Is](#1-what-this-is)
2. [Architecture Overview](#2-architecture-overview)
3. [Component Deep-Dive](#3-component-deep-dive)
   - 3.1 [Base Image](#31-base-image-codercomcode-server)
   - 3.2 [LiteLLM Proxy](#32-litellm-proxy)
   - 3.3 [Continue Extension](#33-continue-extension)
   - 3.4 [MCP Servers](#34-mcp-servers)
   - 3.5 [Supervisord Process Manager](#35-supervisord-process-manager)
   - 3.6 [Entrypoint Script](#36-entrypoint-script)
4. [Configuration Files Reference](#4-configuration-files-reference)
   - 4.1 [litellm-config.yaml](#41-litellm-configyaml)
   - 4.2 [continue-config.yaml](#42-continue-configyaml)
   - 4.3 [code-server.yaml](#43-code-serveryaml)
   - 4.4 [supervisord.conf](#44-supervisordconf)
   - 4.5 [package-lock.json](#45-package-lockjson)
5. [Environment Variables](#5-environment-variables)
6. [Port Map](#6-port-map)
7. [Runtime Startup Sequence](#7-runtime-startup-sequence)
8. [Data Flow: AI Request](#8-data-flow-ai-request)
9. [Networking Notes](#9-networking-notes)
10. [Security Model](#10-security-model)
11. [System Prerequisites](#11-system-prerequisites)
12. [Zero-to-Running: Local Setup Guide](#12-zero-to-running-local-setup-guide)
13. [Troubleshooting](#13-troubleshooting)
14. [Environment-Specific Configuration](#14-environment-specific-configuration)

---

## 1. What This Is

`cloud_mcp` builds a single container image that delivers a **browser-accessible VS Code IDE** pre-configured with an AI coding assistant and a set of MCP (Model Context Protocol) tool servers. It is designed to run anywhere a container runtime is available — locally via Podman/Docker, or on a cloud orchestrator such as AWS ECS.

**Key capabilities out of the box:**

| Capability | How it's provided |
|---|---|
| VS Code in a browser | `code-server` (codercom/code-server base image) |
| AI coding assistant | Continue VS Code extension |
| LLM API access | LiteLLM proxy (routes to OpenAI) |
| Library documentation lookups | Context7 MCP server (`@upstash/context7-mcp`) |
| Structured reasoning | Sequential Thinking MCP server (`@modelcontextprotocol/server-sequential-thinking`) |
| Browser automation | Playwright MCP server (`@playwright/mcp`) |
| Splunk integration | Splunk MCP server (remote HTTP, bearer-token auth) |

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                  Container (root)                    │
│                                                      │
│  ┌──────────────┐       ┌──────────────────────────┐ │
│  │  code-server │       │     LiteLLM proxy        │ │
│  │  (port 8080) │       │  (localhost:4000 only)   │ │
│  │              │       │                          │ │
│  │  Continue    │──────▶│  model: gpt-5.4-mini     │ │
│  │  extension   │ HTTP  │  (openai/gpt-5.4-mini)   │ │
│  │              │       └──────────┬───────────────┘ │
│  │  MCP servers │                  │ HTTPS            │
│  │  (npx stdio) │                  ▼                  │
│  └──────────────┘          [OpenAI API]               │
│                                                      │
│         Both processes managed by supervisord        │
└─────────────────────────────────────────────────────┘
         │ port 8080
         ▼
    [Browser / ALB]
```

**Why LiteLLM sits in the middle:**  
Continue is configured with `provider: openai` pointing at `http://localhost:4000`. LiteLLM translates these OpenAI-format calls to whichever upstream provider is configured (currently `openai/gpt-5.4-mini`). This means Continue never holds an API key — the key lives only in the LiteLLM process, injected via environment variable.

**Why supervisord:**  
A container normally runs one process. supervisord acts as PID 1 and supervises both `code-server` and `litellm` as child processes, streaming their stdout/stderr to the container log, and restarting either if it crashes.

---

## 3. Component Deep-Dive

### 3.1 Base Image: `codercom/code-server`

`Containerfile` starts `FROM codercom/code-server:latest`. This upstream image provides:

- A Debian-based Linux userland
- `code-server` binary at `/usr/bin/code-server`
- The upstream `entrypoint.sh` at `/usr/bin/entrypoint.sh` (launches code-server)
- Node.js and npm (required by MCP servers that run via `npx`)

The build immediately switches to `USER root` and stays there for all subsequent steps. This is intentional — the upstream image's entrypoint expects to run as root when the container process is root, handling home directory setup accordingly.

**Packages added at build time** (via `apt-get`):

| Package | Purpose |
|---|---|
| `curl` | Fetching the Node.js setup script |
| `ca-certificates` | TLS trust for apt/curl |
| `gettext-base` | Provides `envsubst` for config template substitution |
| `python3-pip` | Installs LiteLLM |
| `supervisor` | Process manager (supervisord) |
| `nodejs` (v20 LTS) | Required for MCP servers launched via `npx` |

**Node.js version:** Node 20 LTS is explicitly installed via `nodesource.com/setup_20.x`. The base image ships an older Node version; this upgrade is required because some MCP packages need Node ≥18.

### 3.2 LiteLLM Proxy

LiteLLM is a Python package installed with `pip3 install 'litellm[proxy]'`. The `[proxy]` extra pulls in the HTTP server components needed to run `litellm --config ...`.

**What it does:** Exposes an OpenAI-compatible REST API on `localhost:4000`. When Continue sends a `/v1/chat/completions` request, LiteLLM forwards it to the real OpenAI API, adds authentication, handles retries, and returns the response in the same OpenAI format Continue expects.

**Why `--break-system-packages`:** The base Debian image uses an `externally-managed` Python environment. This flag overrides that guard. It is safe here because the container is purpose-built and we control its full contents.

### 3.3 Continue Extension

Installed at image build time:
```dockerfile
RUN code-server --install-extension Continue.continue
```

This pulls the Continue extension from the Open VSX registry (VS Code's open-source extension marketplace, which code-server uses instead of the Microsoft Marketplace).

**Continue's config file** is a YAML file that code-server reads from `~/.continue/config.yaml` (where `~` is `/root` because the container runs as root). The file is not copied into the image directly — it is written at container startup by `entrypoint.sh` via `envsubst`, so that environment variables (specifically `SPLUNK_MCP_TOKEN`) are substituted before Continue reads it.

**The `package.json` workaround:** Continue's config loader first checks for a compiled `config.js` (for TypeScript-based configs). If it finds a `package.json` without a `main` field, it falls back to `config.yaml`. The entrypoint writes:
```json
{"name":"continue-config","version":"1.0.0"}
```
to `/root/.continue/package.json` to trigger this fallback. Without this file, Continue may attempt to compile or look for JS config and fail to load `config.yaml`.

### 3.4 MCP Servers

MCP (Model Context Protocol) servers give the AI assistant access to external tools and data sources. Continue launches each server as a child process and communicates with it over a defined transport (stdio or HTTP).

Four MCP servers are configured:

#### Context7 (`@upstash/context7-mcp`)
- **Transport:** stdio
- **Launch:** `npx -y @upstash/context7-mcp`
- **Purpose:** Fetches up-to-date library documentation and code examples. When the AI needs to look up an API or library, it queries Context7 rather than relying on potentially-stale training data.
- **Network:** Requires outbound internet access to Upstash's Context7 API.

#### Sequential Thinking (`@modelcontextprotocol/server-sequential-thinking`)
- **Transport:** stdio
- **Launch:** `npx -y @modelcontextprotocol/server-sequential-thinking`
- **Purpose:** Provides a structured thinking tool — the AI can break complex problems into sequential steps. This is a local process with no external network calls.

#### Playwright (`@playwright/mcp@latest`)
- **Transport:** stdio
- **Launch:** `npx @playwright/mcp@latest`
- **Purpose:** Browser automation. The AI can navigate web pages, fill forms, click elements, and take screenshots.
- **Note:** `@latest` (no `-y`) means npx checks for updates on every launch. Browser binaries are downloaded by Playwright on first use — this can take time and requires internet access.

#### Splunk MCP Server
- **Transport:** streamable-http (HTTP SSE)
- **URL:** `https://host.containers.internal:8089/services/mcp`
- **Auth:** Bearer token (`Authorization: Bearer ${SPLUNK_MCP_TOKEN}`)
- **Purpose:** Connects the AI to a Splunk instance. The AI can run SPL searches, retrieve events, and query Splunk data.
- **`host.containers.internal`:** A special DNS name that resolves to the container host. On Podman on Mac, this resolves to the Mac's IP on the Podman bridge. On ECS, this would need to be replaced with the actual Splunk endpoint.
- **Token injection:** `SPLUNK_MCP_TOKEN` is a `${...}` placeholder in the template file (`continue-config.yaml`). The entrypoint substitutes it with the actual value at runtime.

### 3.5 Supervisord Process Manager

supervisord runs as PID 1 (launched by the final `exec supervisord -c ...` in the entrypoint). It manages:

**`[program:code-server]`**
- Command: `/usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 .`  
  (This is the *upstream* code-server entrypoint, not our custom one — our entrypoint already ran before exec'ing supervisord)
- Priority 1 (starts first)

**`[program:litellm]`**
- Command: `litellm --config /root/config/litellm-config.yaml --host 127.0.0.1 --port 4000`
- LiteLLM binds only to `127.0.0.1` — it is not accessible from outside the container.
- Priority 2 (starts after code-server)

Both programs have `autorestart=true`, `stopasgroup=true`, and `killasgroup=true`. All stdout/stderr goes to `/dev/stdout` and `/dev/stderr` respectively (container log), with `maxbytes=0` (no log rotation — let the container runtime handle it).

supervisord itself runs in `nodaemon=true` mode (stays in the foreground), writes its own logs to `/dev/null` (only child process logs are interesting), and stores its PID file at `/tmp/supervisord.pid`.

### 3.6 Entrypoint Script

`docker/entrypoint.sh` runs as the container's `ENTRYPOINT`. It performs two setup steps before handing off to supervisord:

**Step 1 — Write Continue config:**
```bash
envsubst < /root/config/continue-config.yaml > /root/.continue/config.yaml
```
The template at `/root/config/continue-config.yaml` is copied from `docker/config/continue-config.yaml` at build time. `envsubst` replaces `${SPLUNK_MCP_TOKEN}` (and any other `${VAR}` references) with values from the current environment. The result is written to `/root/.continue/config.yaml`, which is where Continue reads its config.

**Step 2 — Write package.json:**
```bash
echo '{"name":"continue-config","version":"1.0.0"}' > /root/.continue/package.json
```
(See [Continue extension section](#33-continue-extension) for why.)

**Step 3 — Launch supervisord:**
```bash
exec supervisord -c /root/config/supervisord.conf
```
`exec` replaces the shell process with supervisord so supervisord becomes PID 1, enabling proper signal handling (SIGTERM, etc.).

---

## 4. Configuration Files Reference

### 4.1 `litellm-config.yaml`

**Built-in location:** `/root/config/litellm-config.yaml`

```yaml
model_list:
  - model_name: gpt-5.4-mini
    litellm_params:
      model: openai/gpt-5.4-mini
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  disable_spend_logs: true
```

**`model_name: gpt-5.4-mini`** — The name Continue uses in its config (`model: gpt-5.4-mini`). This is the name Continue sends in its API requests to LiteLLM.

**`model: openai/gpt-5.4-mini`** — The LiteLLM provider/model string. The `openai/` prefix tells LiteLLM to route to the OpenAI API.

**`api_key: os.environ/OPENAI_API_KEY`** — LiteLLM reads the key from the `OPENAI_API_KEY` environment variable at runtime. The key is never written to any config file.

**`disable_spend_logs: true`** — Suppresses LiteLLM's SQLite-based spend tracking. This keeps the container stateless (no database file created on disk).

**To use a different model:** Change `model_name` and `model` to match. Also update `continue-config.yaml` to reference the new `model_name`. Examples: `openai/gpt-4o`, `openai/gpt-4o-mini`, `anthropic/claude-opus-4-6`.

### 4.2 `continue-config.yaml`

**Template location (build-time):** `/root/config/continue-config.yaml`  
**Runtime destination (after envsubst):** `/root/.continue/config.yaml`

```yaml
name: cloud-ide
version: 1.0.0

models:
  - name: GPT-5.4 Mini
    provider: openai
    model: gpt-5.4-mini
    apiBase: http://localhost:4000
    apiKey: ignored

mcpServers:
  - name: Context7
    type: stdio
    command: npx
    args: [-y, "@upstash/context7-mcp"]

  - name: sequential-thinking
    type: stdio
    command: npx
    args: [-y, "@modelcontextprotocol/server-sequential-thinking"]

  - name: Playwright
    type: stdio
    command: npx
    args: ["@playwright/mcp@latest"]

  - name: splunk-mcp-server
    type: streamable-http
    url: https://host.containers.internal:8089/services/mcp
    requestOptions:
      headers:
        Authorization: Bearer ${SPLUNK_MCP_TOKEN}
      verifySsl: false
```

**`apiBase: http://localhost:4000`** — Points Continue at the local LiteLLM proxy, not directly at OpenAI.

**`apiKey: ignored`** — Continue requires an `apiKey` field even when pointing at a proxy. LiteLLM ignores it; the real key is in `OPENAI_API_KEY`.

**`${SPLUNK_MCP_TOKEN}`** — The only variable substituted at runtime. All other values are static.

**`verifySsl`** — Omitted from the default config (Continue treats the absence as `true`). Add `verifySsl: false` under `requestOptions` only if your Splunk instance uses a self-signed certificate. See [Environment-Specific Configuration](#14-environment-specific-configuration).

### 4.3 `code-server.yaml`

**Built-in location:** `/root/.config/code-server/config.yaml`

```yaml
bind-addr: 0.0.0.0:8080
auth: none
```

**`auth: none`** — Disables code-server's built-in password authentication. In production, an Application Load Balancer (ALB) or similar reverse proxy handles authentication upstream. Locally, this allows direct browser access without a password.

**`bind-addr: 0.0.0.0:8080`** — Listens on all interfaces inside the container. Port 8080 must be mapped to a host port when running with `podman run -p 8080:8080`.

### 4.4 `supervisord.conf`

**Built-in location:** `/root/config/supervisord.conf`

Key settings explained in [Section 3.5](#35-supervisord-process-manager).

### 4.5 `package-lock.json`

**Built-in location:** `docker/config/package-lock.json` (not copied into image)

This file exists in the repo but contains an empty `packages: {}` object. It is present to satisfy any tooling that expects a lockfile alongside `package.json`. It has no effect on the running container.

---

## 5. Environment Variables

| Variable | Required | Where used | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | **Yes** | LiteLLM | OpenAI API key. LiteLLM reads this at startup and uses it for all outbound requests to the OpenAI API. |
| `SPLUNK_MCP_TOKEN` | **Yes** (if Splunk MCP is used) | `entrypoint.sh` → `continue-config.yaml` | Bearer token for authenticating with the Splunk MCP HTTP endpoint. Substituted into the Continue config at startup. If unset, `envsubst` replaces the placeholder with an empty string, and the Splunk MCP server will fail to authenticate. |

No other environment variables are required. However, the following are implicitly used:

| Variable | Where used | Notes |
|---|---|---|
| `HOME` | supervisord, code-server | Should be `/root` since everything runs as root. Set by the shell automatically. |
| `PATH` | All processes | Must include `/usr/local/bin` (where pip installs LiteLLM) and the Node.js bin directory. Both are set correctly by the base image and package installs. |

---

## 6. Port Map

| Port | Protocol | Bound to | Service | Exposed outside container? |
|---|---|---|---|---|
| 8080 | HTTP | 0.0.0.0 | code-server (VS Code) | Yes — must be mapped with `-p 8080:8080` |
| 4000 | HTTP | 127.0.0.1 | LiteLLM proxy | No — localhost only, internal container traffic only |

---

## 7. Runtime Startup Sequence

```
Container starts
      │
      ▼
/entrypoint.sh runs (our script)
      │
      ├─ envsubst: substitute ${SPLUNK_MCP_TOKEN} in continue-config.yaml
      │  └─ writes result to /root/.continue/config.yaml
      │
      ├─ writes /root/.continue/package.json  {"name":"continue-config","version":"1.0.0"}
      │
      └─ exec supervisord -c /root/config/supervisord.conf
             │
             ├─ [priority 1] starts /usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 .
             │    └─ code-server binds port 8080
             │         └─ loads Continue extension
             │              └─ Continue reads /root/.continue/config.yaml
             │                   └─ spawns MCP server subprocesses (npx ...)
             │                         └─ connects to splunk-mcp-server via HTTP
             │
             └─ [priority 2] starts litellm --config ... --host 127.0.0.1 --port 4000
                  └─ LiteLLM reads OPENAI_API_KEY from environment
                       └─ binds localhost:4000
```

**Timing note:** supervisord starts both processes with no delay between them. LiteLLM is typically ready within 2–5 seconds. If Continue attempts an AI request before LiteLLM is fully up, LiteLLM will return a connection-refused error. Continue will surface this as an error in the chat UI; simply retry the request after a moment.

---

## 8. Data Flow: AI Request

```
User types in Continue chat (browser)
      │
      ▼
Continue extension (inside code-server)
      │  POST http://localhost:4000/v1/chat/completions
      │  {model: "gpt-5.4-mini", messages: [...]}
      ▼
LiteLLM proxy (localhost:4000)
      │  maps "gpt-5.4-mini" → openai/gpt-5.4-mini
      │  adds Authorization: Bearer $OPENAI_API_KEY
      │  POST https://api.openai.com/v1/chat/completions
      ▼
OpenAI API
      │
      ▼  response streams back
LiteLLM → Continue → browser
```

**When an MCP tool is called:**
```
Continue sends tool_call in LLM response
      │
      ▼
Continue spawns/calls MCP server
  ├─ stdio servers (Context7, sequential-thinking, Playwright):
  │    npx process already running, communicates via stdin/stdout
  │
  └─ Splunk (streamable-http):
       POST https://host.containers.internal:8089/services/mcp
       Authorization: Bearer <token>
       (SSL verification disabled)
```

---

## 9. Networking Notes

**`host.containers.internal`**  
This hostname is used in the Splunk MCP server URL. It is a special name that resolves to the container host:
- On **Podman on Mac:** resolves to the Mac's IP on the Podman internal bridge (typically something in the `10.88.x.x` range, injected into `/etc/hosts` by Podman)
- On **Docker on Mac:** use `host.docker.internal` instead — `host.containers.internal` may not resolve
- On **ECS/Linux:** this name does not exist by default. The Splunk URL must be changed to the actual Splunk hostname or IP when deploying to cloud infrastructure.

**Outbound connectivity required:**
- `api.openai.com` — LiteLLM → OpenAI API
- `upstash.com` — Context7 MCP server
- npm registry (`registry.npmjs.org`) — `npx` downloads MCP packages on first use
- Your Splunk endpoint — Splunk MCP server

---

## 10. Security Model

| Concern | Approach |
|---|---|
| API keys | `OPENAI_API_KEY` is never written to disk; only held in the LiteLLM process environment. `SPLUNK_MCP_TOKEN` is written into `/root/.continue/config.yaml` at runtime — this file is in the container's ephemeral filesystem. |
| code-server auth | Disabled (`auth: none`). Access control must be enforced upstream (ALB, VPN, firewall). **Do not expose port 8080 to the public internet without an authentication layer.** |
| LiteLLM exposure | LiteLLM binds to `127.0.0.1:4000` only. It is not reachable from outside the container. |
| TLS verification | Both Python (LiteLLM/certifi) and Node.js (MCP stdio servers) verify TLS normally by default. See [Environment-Specific Configuration](#14-environment-specific-configuration) if you need to override this for self-signed certs or a TLS inspection proxy. |
| Container user | Runs as `root`. Required by the upstream code-server entrypoint behavior. This is a known limitation; reducing to a non-root user would require patching the upstream entrypoint. |

---

## 11. System Prerequisites

These must be present on the machine that **builds and runs** the container.

### Build host requirements

| Requirement | Version | Notes |
|---|---|---|
| Container runtime | Podman ≥4.x or Docker ≥24.x | Podman is recommended (daemonless, rootless-capable). Docker works with `docker build`/`docker run` substituted for `podman build`/`podman run`. |
| Internet access | — | The build pulls the base image from Docker Hub and installs packages via apt, pip, and the Open VSX registry. |

### Runtime host requirements

| Requirement | Notes |
|---|---|
| Container runtime (same as above) | Must be running (Podman machine started on Mac) |
| Outbound internet access | LiteLLM calls OpenAI; `npx` downloads MCP servers on first use; Context7 calls Upstash |
| `OPENAI_API_KEY` | Valid OpenAI API key with access to the configured model |
| `SPLUNK_MCP_TOKEN` | Bearer token for your Splunk MCP endpoint (required only if the Splunk MCP server is in use) |
| Splunk MCP server accessible | The URL `https://host.containers.internal:8089/services/mcp` must be reachable from inside the container. Change this URL in `continue-config.yaml` if your Splunk endpoint is elsewhere. |

### Nothing else required

- No local Node.js installation needed (Node 20 is installed inside the container)
- No local Python installation needed (Python and LiteLLM are inside the container)
- No local VS Code installation needed (code-server is inside the container)
- No pre-installed npm packages needed (MCP servers are fetched via `npx` at runtime)

---

## 12. Zero-to-Running: Local Setup Guide

This guide takes you from a clean machine to a running IDE in a browser.

### Step 1: Install Podman

**macOS:**
```bash
brew install podman
podman machine init --memory 4096
podman machine start
```

Verify:
```bash
podman info --format '{{.Host.OS}}'
# Expected: linux
```

> **Memory note:** The default Podman machine has 2 GiB RAM. 4 GiB is recommended — code-server, LiteLLM, and the MCP servers together use ~1.5–2 GiB.

**Linux:** Install via your package manager (`apt install podman` or `dnf install podman`). No machine init needed on Linux — containers run natively.

**Docker alternative:** Replace every `podman` command below with `docker`. Replace `host.containers.internal` in `continue-config.yaml` with `host.docker.internal`.

---

### Step 2: Clone the repository

```bash
git clone <repository-url> cloud_mcp
cd cloud_mcp
```

---

### Step 3: Review and adjust configuration (optional)

**To use a different OpenAI model:**

Edit `docker/config/litellm-config.yaml` — change both occurrences of `gpt-5.4-mini`:
```yaml
model_list:
  - model_name: gpt-4o-mini          # ← name Continue will use
    litellm_params:
      model: openai/gpt-4o-mini      # ← actual OpenAI model
      api_key: os.environ/OPENAI_API_KEY
```

Then update `docker/config/continue-config.yaml` to match:
```yaml
models:
  - name: GPT-4o Mini
    model: gpt-4o-mini               # ← must match model_name above
```

**To change the Splunk MCP endpoint:**

Edit `docker/config/continue-config.yaml`:
```yaml
  - name: splunk-mcp-server
    type: streamable-http
    url: https://your-splunk-host:8089/services/mcp   # ← change this
```

**To disable the Splunk MCP server entirely:**

Remove the `splunk-mcp-server` block from `continue-config.yaml`. You can still run without setting `SPLUNK_MCP_TOKEN`.

---

### Step 5: Build the image

From the repository root:
```bash
podman build -t cloud-ide docker/
```

Expected final line: `Successfully tagged localhost/cloud-ide:latest`

The build takes 3–8 minutes on first run (downloading base image, installing packages, installing Continue extension). Subsequent builds are faster due to layer caching.

**If the build fails at `code-server --install-extension Continue.continue`:** This step fetches from Open VSX. Check your internet connection. If behind a proxy, ensure `HTTP_PROXY`/`HTTPS_PROXY` are set in your shell.

---

### Step 6: Run the container

**Minimum required (no Splunk):**
```bash
podman run -d \
  -p 8080:8080 \
  -e OPENAI_API_KEY=sk-your-key-here \
  -e SPLUNK_MCP_TOKEN=placeholder \
  --name cloud-ide \
  cloud-ide
```

**With Splunk MCP:**
```bash
podman run -d \
  -p 8080:8080 \
  -e OPENAI_API_KEY=sk-your-key-here \
  -e SPLUNK_MCP_TOKEN=your-splunk-bearer-token \
  --name cloud-ide \
  cloud-ide
```

> **`SPLUNK_MCP_TOKEN` is always substituted.** Even if you don't use Splunk, you must pass a value (can be any string) to prevent `envsubst` from leaving an empty `Authorization: Bearer ` header.

---

### Step 7: Verify the container started

```bash
podman logs cloud-ide
```

Expected output (order may vary):
```
Continue config written to /root/.continue/config.yaml
2024-... INFO supervisord started with pid 1
2024-... INFO spawned: 'code-server' with pid ...
2024-... INFO spawned: 'litellm' with pid ...
```

Within ~10 seconds you should see code-server log lines indicating it's listening on port 8080.

---

### Step 8: Open the IDE

Navigate to `http://localhost:8080` in your browser. VS Code should load without a password prompt.

**To verify Continue is working:**
1. Click the Continue icon in the left activity bar (looks like a play button or chat bubble)
2. Type: `Hello, are you there?`
3. Expected: A response streams back from the LLM

**To verify LiteLLM is running:**
```bash
podman exec cloud-ide curl -s http://localhost:4000/health
# Expected: {"status":"healthy"} or similar JSON
```

---

### Step 9: Stopping and cleaning up

```bash
podman stop cloud-ide
podman rm cloud-ide
```

To also remove the built image:
```bash
podman rmi cloud-ide
```

---

## 13. Troubleshooting

### Continue shows "connection refused" or no response

LiteLLM may not be ready yet. Wait 5 seconds and retry. If it persists:
```bash
podman exec cloud-ide curl -s http://localhost:4000/health
```
If that fails, LiteLLM crashed:
```bash
podman logs cloud-ide | grep -i "litellm\|error"
```
Common cause: `OPENAI_API_KEY` is missing or invalid.

---

### "Invalid API key" error from OpenAI

Your `OPENAI_API_KEY` is incorrect or lacks access to the configured model. Verify with:
```bash
curl https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | head -c 200
```

---

### MCP servers not appearing in Continue

Continue loads MCP servers when it first starts. If you just opened the IDE, wait 10–15 seconds. If `npx` needs to download packages, it may take longer.

Check Continue's logs via VS Code: `Help → Toggle Developer Tools → Console`.

---

### Splunk MCP shows auth error

Verify your token:
```bash
podman exec cloud-ide cat /root/.continue/config.yaml | grep Authorization
# Expected: Authorization: Bearer <your-actual-token>
# Bad: Authorization: Bearer ${SPLUNK_MCP_TOKEN}  ← envsubst didn't substitute
```

If you see the literal `${SPLUNK_MCP_TOKEN}`, the variable was not set when the container started. Stop and re-run with `-e SPLUNK_MCP_TOKEN=...`.

---

### `host.containers.internal` doesn't resolve (Docker users)

Edit `docker/config/continue-config.yaml` and replace:
```yaml
url: https://host.containers.internal:8089/services/mcp
```
with:
```yaml
url: https://host.docker.internal:8089/services/mcp
```
Then rebuild the image.

---

### Container exits immediately

```bash
podman logs cloud-ide
```
Look for the error. Common causes:
- `entrypoint.sh` hit `set -e` on a failing command (check for file-not-found errors)
- supervisord config error (look for `Error: No config file found`)

---

### TLS errors in browser console or MCP servers

See [Environment-Specific Configuration](#14-environment-specific-configuration) for how to configure TLS bypass options when using self-signed certificates or a corporate TLS inspection proxy.

---

## 14. Environment-Specific Configuration

The default configuration assumes standard TLS (trusted CA, no interception proxy). Two scenarios require overrides:

---

### Self-signed certificate on the Splunk endpoint

If your Splunk instance uses a self-signed certificate, Continue will refuse the connection with a TLS verification error. Add `verifySsl: false` to the Splunk MCP server entry in `docker/config/continue-config.yaml`:

```yaml
  - name: splunk-mcp-server
    type: streamable-http
    url: https://host.containers.internal:8089/services/mcp
    requestOptions:
      headers:
        Authorization: Bearer ${SPLUNK_MCP_TOKEN}
      verifySsl: false       # ← add this line
```

This disables TLS verification only for the Splunk MCP connection. All other connections (LiteLLM → OpenAI, npx MCP servers) are unaffected.

---

### Corporate TLS inspection proxy (e.g. Cisco Umbrella)

A TLS inspection proxy intercepts outbound HTTPS and re-signs it with a corporate CA. Two separate trust stores need the CA added: Python's (used by LiteLLM) and Node.js's (used by MCP stdio servers).

Both changes are pre-written as commented-out blocks in the config files — you only need to uncomment them and provide the cert file.

#### 1. Python / LiteLLM — add CA to certifi bundle

**Finding the cert on your machine:**

The cert is installed by Cisco Umbrella as a trusted root. Where to find it:

- **macOS** — export it from the System keychain:
  ```bash
  security find-certificate -c "Cisco" -p /Library/Keychains/System.keychain > docker/config/cisco-ca.crt
  ```
  If that returns nothing, try searching by your organization's name instead of "Cisco", or open Keychain Access, find the root CA under System → Certificates, and export it as PEM.

- **Linux** — the cert is typically installed into the system trust store by your IT provisioning:
  ```bash
  # Debian/Ubuntu
  ls /usr/local/share/ca-certificates/ | grep -i cisco
  # RHEL/Fedora
  ls /etc/pki/ca-trust/source/anchors/ | grep -i cisco
  ```
  Copy the matching `.crt` or `.pem` file to `docker/config/cisco-ca.crt`.

- **Either platform** — your IT team may have a direct download URL for the PEM file, which is the most reliable source.

Once you have the cert:

1. Place it at `docker/config/cisco-ca.crt` (`docker/config/` is in `.gitignore` — the cert is never committed)
2. In `docker/Containerfile`, uncomment the two lines in the Cisco block:
   ```dockerfile
   COPY config/cisco-ca.crt /tmp/cisco-ca.crt
   RUN cat /tmp/cisco-ca.crt >> $(python3 -m certifi) && rm /tmp/cisco-ca.crt
   ```

#### 2. Node.js / MCP servers — disable TLS verification

Node.js does not use the system certificate store, so the CA injection above is not sufficient for MCP stdio servers. In `docker/config/supervisord.conf`, uncomment the line in the Cisco block under `[program:code-server]`:

```ini
environment=NODE_TLS_REJECT_UNAUTHORIZED="0"
```

This disables TLS verification for all Node.js processes spawned under that supervisord program. It is a broad bypass — use only in environments where the proxy is trusted and network access is otherwise controlled.

#### 3. Rebuild

After making both changes, rebuild the image:
```bash
podman build -t cloud-ide docker/
```
