# Local Container Build: VS Code + Cline + Bedrock + MCP

## Context

Before deploying to AWS (see `2026-03-24-cloud-ide-design.md`), we build and validate the container locally using Podman. The goal is to iterate incrementally — one working stage at a time — so each component is verified before the next is added.

This spec covers the local development workflow only. The output is a `Containerfile` and supporting files in `docker/` that serve as the foundation for the eventual AWS deployment.

---

## Goals

- Get VS Code (code-server) running in a browser locally via Podman
- Add Cline extension and verify it loads
- Wire Cline to Amazon Bedrock using local AWS credentials
- Configure Cline's MCP client to connect to a local Splunk MCP endpoint
- Add a skills directory that Cline picks up at startup

## Non-Goals

- AWS infrastructure (handled in the cloud-ide-design spec)
- Auth (disabled for local dev; Show environment handles it in prod)
- Multi-user or workspace orchestration
- Production hardening

---

## Podman Primer

Podman is a daemonless Docker replacement. Key points for a Docker user:

- `podman` replaces `docker` in every command — the CLI is compatible
- Uses `Containerfile` by convention (but `Dockerfile` works too)
- Runs rootless by default on Mac (containers run as your user)
- On Mac, containers run inside a lightweight Linux VM (`podman machine`)
- Docker Hub pulls work out of the box

**Installation:**
```bash
brew install podman
podman machine init
podman machine start
```

---

## Project Structure

Files live in `docker/` at the repo root. The directory grows as steps are completed:

**After step 1:**
```
docker/
├── Containerfile
└── entrypoint.sh
```

**After all steps:**
```
docker/
├── Containerfile
├── entrypoint.sh
├── config/
│   ├── code-server.yaml   # code-server config (port, auth: none)
│   └── cline-mcp.json     # MCP config template (env var substitution at startup)
└── skills/
    └── splunk-basics.md   # starter skill file
```

---

## Approach

Single `Containerfile`, built and tested incrementally. Each step maps to a git commit. We verify each stage works before moving on — no skipping ahead.

No `podman-compose` at this stage. One container, run by hand with `podman run`. Compose can be added later if multi-container orchestration becomes necessary.

---

## The Five Steps

### Step 1: Base Image

**Goal:** VS Code loads in a browser at `http://localhost:8080`.

Run the upstream `codercom/code-server` image directly — no `Containerfile` yet. Verify it works before writing any custom image.

```bash
podman run -d -p 8080:8080 \
  -e PASSWORD="" \
  codercom/code-server --auth none
```

Once verified, write a minimal `Containerfile` that extends the base image (even if it adds nothing yet) to establish the pattern for subsequent steps.

**Commit:** `feat: base image running`

---

### Step 2: Cline Extension

**Goal:** Cline appears in the VS Code sidebar.

Add to `Containerfile`: download the Cline `.vsix` at build time via `ADD` with a pinned GitHub Releases URL, then install it with `code-server --install-extension`. Node.js is available in the `codercom/code-server` base image (it ships with it), which is required for `npx mcp-remote` in Step 4.

```dockerfile
FROM codercom/code-server:latest

ARG CLINE_VERSION=3.14.1
ADD https://github.com/cline/cline/releases/download/v${CLINE_VERSION}/cline-${CLINE_VERSION}.vsix /tmp/cline.vsix
RUN code-server --install-extension /tmp/cline.vsix && rm /tmp/cline.vsix
```

The version is pinned via `ARG CLINE_VERSION`. To update, change the ARG value and rebuild. Verify the exact release filename on [Cline's GitHub Releases](https://github.com/cline/cline/releases) before building.

**Commit:** `feat: add cline extension`

---

### Step 3: Bedrock

**Goal:** Cline can call Amazon Bedrock (Claude) from inside the container.

No image changes. Mount local AWS credentials at runtime and set the region:

```bash
podman run -d -p 8080:8080 \
  -v ~/.aws:/home/coder/.aws:ro \
  -e AWS_REGION=us-west-2 \
  cloud-ide
```

Configure Cline's AI provider to use Bedrock + the target Claude model via VS Code settings (can be baked into the image as a default settings file).

**Commit:** `feat: wire bedrock`

---

### Step 4: MCP

**Goal:** Cline can connect to the local Splunk MCP endpoint.

Add `config/cline-mcp.json` to the image as a template with env var placeholders. `entrypoint.sh` substitutes `SPLUNK_MCP_URL` and `SPLUNK_MCP_TOKEN` at container startup and writes the resolved config to the path Cline reads from.

**MCP config template:**
```json
{
  "mcpServers": {
    "splunk-mcp-server": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "${SPLUNK_MCP_URL}",
        "--header",
        "Authorization: Bearer ${SPLUNK_MCP_TOKEN}"
      ]
    }
  }
}
```

For local dev, pass credentials as `-e` flags to `podman run`:
```bash
podman run -d -p 8080:8080 \
  -e SPLUNK_MCP_URL=http://localhost:... \
  -e SPLUNK_MCP_TOKEN=... \
  cloud-ide
```

**Commit:** `feat: configure mcp`

---

### Step 5: Skills

**Goal:** Cline picks up skill files from `/workspace/skills/` at startup.

`entrypoint.sh` reads markdown files from `/workspace/skills/` and injects their content into Cline's custom instructions config. For local dev, mount a local `skills/` directory into the container:

```bash
podman run -d -p 8080:8080 \
  -v $(pwd)/docker/skills:/workspace/skills:ro \
  cloud-ide
```

A starter `splunk-basics.md` skill file is included in `docker/skills/`.

**Commit:** `feat: add skills`

---

## Runtime Command (final, all steps combined)

```bash
podman run -d -p 8080:8080 \
  -v ~/.aws:/home/coder/.aws:ro \
  -v $(pwd)/docker/skills:/workspace/skills:ro \
  -e AWS_REGION=us-west-2 \
  -e SPLUNK_MCP_URL=http://your-local-mcp-endpoint \
  -e SPLUNK_MCP_TOKEN=your-token \
  cloud-ide
```

---

## Relationship to AWS Spec

The `docker/` directory produced by this local build is the same `docker/` directory referenced in `2026-03-24-cloud-ide-design.md`. The only differences in production:

- AWS credentials come from the ECS task IAM role (not a mounted `~/.aws`)
- `SPLUNK_MCP_URL` and `SPLUNK_MCP_TOKEN` come from AWS Secrets Manager (not `-e` flags)
- Workspace files persist on EFS (not in the container)
- Auth is handled by the Show ALB (not disabled)
