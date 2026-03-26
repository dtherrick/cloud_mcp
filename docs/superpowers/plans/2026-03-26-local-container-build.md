# Local Container Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local Podman container running VS Code (code-server) with Cline, wired to Amazon Bedrock and a local Splunk MCP endpoint, incrementally verified at each stage.

**Architecture:** Single container based on `codercom/code-server`, extended via `Containerfile`. Each of the 5 build stages is independently verified before proceeding. No orchestration tooling — container is run by hand with `podman run`.

**Tech Stack:** Podman, codercom/code-server, Cline VS Code extension (vsix), Amazon Bedrock (Claude), npx mcp-remote, bash (entrypoint script)

**Spec:** `docs/superpowers/specs/2026-03-26-local-container-design.md`

---

## File Map

| File | Purpose |
|------|---------|
| `docker/Containerfile` | Image definition — grows with each step |
| `docker/entrypoint.sh` | Container startup script — sets up workspace, injects config |
| `docker/config/code-server.yaml` | code-server config (port, auth disabled) |
| `docker/config/cline-mcp.json.tpl` | MCP config template with `${VAR}` placeholders |
| `docker/skills/splunk-basics.md` | Starter skill file for Cline |

---

## Task 1: Start Podman Machine

**Files:** none

- [ ] **Step 1: Set machine memory to 4GiB before starting**

  The default 2GiB is tight for code-server + Cline. The machine has been initialized but not yet started, so this will work. If you ever need to do this after the machine has been started, stop it first with `podman machine stop`.

  ```bash
  podman machine set --memory 4096
  ```

- [ ] **Step 2: Start the podman machine**

  ```bash
  podman machine start
  ```

  Expected output: `Machine "podman-machine-default" started successfully`

- [ ] **Step 3: Verify podman is working**

  ```bash
  podman info --format '{{.Host.OS}}'
  ```

  Expected: `linux` (the VM's OS, not your Mac)

- [ ] **Step 4: Commit**

  Nothing to commit — machine config is not tracked in git. Proceed to Task 2.

---

## Task 2: Verify Base Image (Step 1)

**Goal:** VS Code loads in a browser at `http://localhost:8080`.

**Files:** none yet — we run the upstream image directly first.

- [ ] **Step 1: Pull and run codercom/code-server**

  ```bash
  podman run -d --name code-server-test -p 8080:8080 \
    -e PASSWORD="" \
    codercom/code-server \
    --auth none
  ```

- [ ] **Step 2: Verify the container is running**

  ```bash
  podman ps
  ```

  Expected: `code-server-test` listed with status `Up`.

- [ ] **Step 3: Verify VS Code loads in browser**

  Open `http://localhost:8080` in your browser.

  Expected: VS Code editor loads without password prompt.

- [ ] **Step 4: Verify Node.js is available in the container**

  This is required for `npx mcp-remote` in Task 5.

  ```bash
  podman exec code-server-test node --version
  podman exec code-server-test npm --version
  ```

  Expected: version strings printed for both. If either fails, we need to install Node.js in the Containerfile — stop and address before continuing.

- [ ] **Step 5: Stop and remove the test container**

  ```bash
  podman rm -f code-server-test
  ```

- [ ] **Step 6: Write minimal Containerfile**

  Create `docker/Containerfile`:

  ```dockerfile
  # ABOUTME: Builds the cloud-ide image: VS Code (code-server) + Cline + Bedrock + MCP
  # ABOUTME: Built incrementally — each task in the plan adds one layer of functionality.

  FROM codercom/code-server:latest
  ```

  Create `docker/entrypoint.sh`:

  ```bash
  #!/usr/bin/env bash
  # ABOUTME: Container startup script — configures workspace and launches code-server.
  # ABOUTME: Handles MCP config template substitution and skill injection at startup.

  set -euo pipefail

  exec /usr/bin/entrypoint.sh "$@"
  ```

  Make it executable:

  ```bash
  chmod +x docker/entrypoint.sh
  ```

- [ ] **Step 7: Build and run the custom image**

  ```bash
  podman build -t cloud-ide docker/
  podman run -d --name cloud-ide-test -p 8080:8080 \
    cloud-ide \
    --auth none
  ```

- [ ] **Step 8: Verify VS Code still loads**

  Open `http://localhost:8080`. Expected: VS Code loads as before.

- [ ] **Step 9: Stop and remove**

  ```bash
  podman rm -f cloud-ide-test
  ```

- [ ] **Step 10: Commit**

  ```bash
  git add docker/Containerfile docker/entrypoint.sh
  git commit -m "feat: base image running"
  ```

---

## Task 3: Install Cline Extension (Step 2)

**Goal:** Cline appears in the VS Code Extensions sidebar.

**Files:**
- Modify: `docker/Containerfile`

- [ ] **Step 1: Verify the Cline vsix URL is correct**

  ```bash
  curl -sI "https://github.com/cline/cline/releases/download/v3.75.0/cline-3.75.0.vsix" \
    | grep -i "^http\|^location\|^content-type"
  ```

  Expected: HTTP 302 redirect (GitHub releases redirect to S3). If you get 404, check https://github.com/cline/cline/releases for the correct filename.

- [ ] **Step 2: Add Cline installation to Containerfile**

  Append to `docker/Containerfile`:

  ```dockerfile

  # Install Cline extension
  ARG CLINE_VERSION=3.75.0
  ADD https://github.com/cline/cline/releases/download/v${CLINE_VERSION}/cline-${CLINE_VERSION}.vsix /tmp/cline.vsix
  RUN code-server --install-extension /tmp/cline.vsix && rm /tmp/cline.vsix
  ```

  > **Note:** `ADD` with HTTPS URLs follows redirects automatically. If the build fails with a network error, try pre-downloading the vsix and using `COPY` instead:
  > ```bash
  > curl -L -o docker/cline.vsix "https://github.com/cline/cline/releases/download/v3.75.0/cline-3.75.0.vsix"
  > ```
  > Then replace the `ARG`/`ADD` lines with `COPY cline.vsix /tmp/cline.vsix`.

- [ ] **Step 3: Build the image**

  ```bash
  podman build -t cloud-ide docker/
  ```

  Expected: build completes, final line is `Successfully tagged localhost/cloud-ide:latest`.

  If the build fails at the `ADD` step with a TLS or redirect error, use the `COPY` fallback from the note above.

- [ ] **Step 4: Run the container**

  ```bash
  podman run -d --name cloud-ide-test -p 8080:8080 \
    cloud-ide --auth none
  ```

- [ ] **Step 5: Verify Cline is installed**

  Open `http://localhost:8080`. In VS Code:
  - Open the Extensions panel (Ctrl+Shift+X or Cmd+Shift+X)
  - Search for "Cline"
  - Expected: Cline appears with status "Installed" (not "Install")
  - Also check the Activity Bar on the left for the Cline icon

- [ ] **Step 6: Stop and remove**

  ```bash
  podman rm -f cloud-ide-test
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add docker/Containerfile
  git commit -m "feat: add cline extension"
  ```

  If you used the `COPY` fallback, also add the vsix — but first add it to `.gitignore` (it's a large binary, we don't want it in git):

  ```bash
  echo "docker/*.vsix" >> .gitignore
  git add .gitignore
  git commit -m "feat: add cline extension"
  ```

---

## Task 4: Wire Bedrock (Step 3)

**Goal:** Cline can be configured to call Amazon Bedrock (Claude) from inside the container.

**Files:**
- Modify: `docker/Containerfile`
- Create: `docker/config/code-server.yaml`
- Modify: `docker/entrypoint.sh`

**Prerequisites:** Bedrock model access must be enabled in your AWS account for the target region. Navigate to AWS Console → Bedrock → Model access → enable Claude Sonnet or Haiku.

- [ ] **Step 1: Create code-server config**

  Create `docker/config/` directory and `docker/config/code-server.yaml`:

  ```yaml
  # ABOUTME: code-server runtime configuration.
  # ABOUTME: Auth is disabled — handled by the Show ALB in production, and not needed locally.
  bind-addr: 0.0.0.0:8080
  auth: none
  ```

- [ ] **Step 2: Create default VS Code settings with Bedrock config**

  Create `docker/config/settings.json`:

  ```json
  {
    "cline.apiProvider": "bedrock",
    "cline.apiModelId": "anthropic.claude-sonnet-4-5",
    "cline.awsRegion": "us-west-2"
  }
  ```

  > **Note:** `cline.apiModelId` may need adjustment based on which models are enabled in your Bedrock account. Alternatives: `anthropic.claude-3-5-sonnet-20241022-v2:0`, `anthropic.claude-3-haiku-20240307-v1:0`. You'll verify this when you test in Step 6.

- [ ] **Step 3: Update Containerfile to copy configs**

  Append to `docker/Containerfile`:

  ```dockerfile

  # Copy code-server and VS Code default settings
  COPY config/code-server.yaml /home/coder/.config/code-server/config.yaml
  USER root
  RUN mkdir -p /home/coder/.local/share/code-server/User
  COPY config/settings.json /home/coder/.local/share/code-server/User/settings.json
  RUN chown -R coder:coder /home/coder/.config /home/coder/.local
  USER coder
  ```

- [ ] **Step 4: Build the image**

  ```bash
  podman build -t cloud-ide docker/
  ```

  Expected: build completes successfully.

- [ ] **Step 5: Run with AWS credentials mounted**

  ```bash
  podman run -d --name cloud-ide-test -p 8080:8080 \
    -v ~/.aws:/home/coder/.aws:ro \
    -e AWS_REGION=us-west-2 \
    cloud-ide
  ```

  > Note: we drop `--auth none` now since `code-server.yaml` sets `auth: none`.

- [ ] **Step 6: Verify Bedrock connectivity**

  Open `http://localhost:8080`. Open Cline (Activity Bar icon or Extensions panel).

  - Cline should show it's configured for Bedrock/Claude
  - Type a simple test message: "Say hello"
  - Expected: Cline responds via Claude through Bedrock

  If Cline shows an auth error or can't find credentials, check:
  ```bash
  podman exec cloud-ide-test ls /home/coder/.aws/
  podman exec cloud-ide-test cat /home/coder/.aws/credentials
  ```

- [ ] **Step 7: Stop and remove**

  ```bash
  podman rm -f cloud-ide-test
  ```

- [ ] **Step 8: Commit**

  ```bash
  git add docker/Containerfile docker/config/code-server.yaml docker/config/settings.json
  git commit -m "feat: wire bedrock"
  ```

---

## Task 5: Configure MCP (Step 4)

**Goal:** Cline can connect to your local Splunk MCP endpoint.

**Files:**
- Create: `docker/config/cline-mcp.json.tpl`
- Modify: `docker/entrypoint.sh`
- Modify: `docker/Containerfile`

**Prerequisites:** Your local Splunk MCP server must be running and accessible from inside the Podman VM. Note: `localhost` inside the container refers to the container, not your Mac. Use your Mac's IP on the Podman bridge network instead (usually `10.0.2.2` or found via `podman machine inspect`).

- [ ] **Step 1: Find the host IP accessible from inside the container**

  Run this to find the gateway IP (your Mac's address from inside the container):

  ```bash
  podman run --rm codercom/code-server ip route | grep default
  ```

  Expected output like: `default via 10.0.2.2 dev eth0`. The gateway address (e.g., `10.0.2.2`) is what you use instead of `localhost` when pointing at your Mac's Splunk MCP server.

- [ ] **Step 2: Create MCP config template**

  Create `docker/config/cline-mcp.json.tpl`:

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

- [ ] **Step 3: Update entrypoint.sh to substitute and place MCP config**

  Replace the contents of `docker/entrypoint.sh` with:

  ```bash
  #!/usr/bin/env bash
  # ABOUTME: Container startup script — configures workspace and launches code-server.
  # ABOUTME: Handles MCP config template substitution and skill injection at startup.

  set -euo pipefail

  MCP_CONFIG_DIR="/home/coder/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev"
  MCP_CONFIG_FILE="${MCP_CONFIG_DIR}/settings/cline_mcp_settings.json"

  # Substitute env vars into MCP config template and write to Cline's settings path
  if [[ -f /home/coder/config/cline-mcp.json.tpl ]]; then
    mkdir -p "$(dirname "${MCP_CONFIG_FILE}")"
    envsubst < /home/coder/config/cline-mcp.json.tpl > "${MCP_CONFIG_FILE}"
    echo "MCP config written to ${MCP_CONFIG_FILE}"
  fi

  exec /usr/bin/entrypoint.sh "$@"
  ```

  > **Note on the MCP config path:** Cline stores its MCP server settings at
  > `~/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json`
  > in code-server. If this path is wrong for the version of Cline you installed,
  > open Cline in the browser UI → Settings → MCP Servers and note the path it
  > shows, then update the `MCP_CONFIG_FILE` variable accordingly.

- [ ] **Step 4: Update Containerfile to copy MCP template and install envsubst**

  Append to `docker/Containerfile`:

  ```dockerfile

  # Install envsubst (part of gettext) for MCP config template substitution
  USER root
  RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*
  USER coder

  # Copy MCP config template
  COPY config/cline-mcp.json.tpl /home/coder/config/cline-mcp.json.tpl

  # Use our entrypoint
  COPY entrypoint.sh /home/coder/entrypoint.sh
  RUN chmod +x /home/coder/entrypoint.sh
  ENTRYPOINT ["/home/coder/entrypoint.sh"]
  ```

- [ ] **Step 5: Build the image**

  ```bash
  podman build -t cloud-ide docker/
  ```

- [ ] **Step 6: Run with MCP env vars**

  Replace `http://HOST_IP:PORT` with your local Splunk MCP endpoint. Use the host gateway IP from Step 1 (e.g., `10.0.2.2`) rather than `localhost`.

  ```bash
  podman run -d --name cloud-ide-test -p 8080:8080 \
    -v ~/.aws:/home/coder/.aws:ro \
    -e AWS_REGION=us-west-2 \
    -e SPLUNK_MCP_URL=http://HOST_IP:PORT \
    -e SPLUNK_MCP_TOKEN=your-token \
    cloud-ide
  ```

- [ ] **Step 7: Verify MCP config was written**

  ```bash
  podman exec cloud-ide-test cat \
    /home/coder/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json
  ```

  Expected: JSON with your `SPLUNK_MCP_URL` substituted in (not the `${...}` placeholder).

- [ ] **Step 8: Verify Cline connects to the MCP server**

  Open `http://localhost:8080`. Open Cline. Navigate to MCP Servers settings.

  Expected: `splunk-mcp-server` listed and showing as connected (green indicator).

  If it shows an error, check:
  - Is your local MCP server actually running?
  - Is the host IP correct? Try `ping 10.0.2.2` from inside the container:
    ```bash
    podman exec cloud-ide-test ping -c 1 10.0.2.2
    ```

- [ ] **Step 9: Stop and remove**

  ```bash
  podman rm -f cloud-ide-test
  ```

- [ ] **Step 10: Commit**

  ```bash
  git add docker/Containerfile docker/entrypoint.sh docker/config/cline-mcp.json.tpl
  git commit -m "feat: configure mcp"
  ```

---

## Task 6: Add Skills (Step 5)

**Goal:** Cline picks up skill files from `/workspace/skills/` at container startup.

**Files:**
- Modify: `docker/entrypoint.sh`
- Create: `docker/skills/splunk-basics.md`
- Modify: `docker/Containerfile`

- [ ] **Step 1: Create the starter skill file**

  Create `docker/skills/splunk-basics.md`:

  ```markdown
  # Splunk Basics

  You have access to a Splunk MCP server (`splunk-mcp-server`). Use it to:

  - Run SPL (Search Processing Language) queries against Splunk
  - Retrieve events, statistics, and time-series data
  - Investigate errors, anomalies, and operational metrics

  ## How to query Splunk

  Use the `search` tool from `splunk-mcp-server`. Always scope searches with a time range.

  Example: to find the top 10 errors in the last hour:
  ```
  index=* level=ERROR earliest=-1h | stats count by source | sort -count | head 10
  ```

  ## Tips

  - Use `earliest` and `latest` to bound time ranges (e.g., `earliest=-1h`, `earliest=-24h@d`)
  - Use `| head N` to limit large result sets
  - Use `| stats count by field` for aggregations
  ```

- [ ] **Step 2: Update entrypoint.sh to inject skills into Cline**

  Add skill injection before the `exec` line in `docker/entrypoint.sh`:

  ```bash
  CLINE_SETTINGS_DIR="/home/coder/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev"
  CLINE_SETTINGS_FILE="${CLINE_SETTINGS_DIR}/settings.json"
  SKILLS_DIR="/workspace/skills"

  # Inject skills into Cline's custom instructions
  if [[ -d "${SKILLS_DIR}" ]] && compgen -G "${SKILLS_DIR}/*.md" > /dev/null; then
    mkdir -p "${CLINE_SETTINGS_DIR}"

    # Concatenate all skill files into a temp file to avoid argv/newline issues
    SKILLS_TEMP=$(mktemp)
    for skill_file in "${SKILLS_DIR}"/*.md; do
      cat "${skill_file}" >> "${SKILLS_TEMP}"
      printf "\n\n" >> "${SKILLS_TEMP}"
    done

    # Write or merge into Cline settings JSON, reading skill content from file
    python3 - "${CLINE_SETTINGS_FILE}" "${SKILLS_TEMP}" <<'PYEOF'
  import json, sys, os
  settings_file = sys.argv[1]
  skills_file = sys.argv[2]
  with open(skills_file) as f:
      skills_content = f.read()
  s = {}
  if os.path.exists(settings_file):
      with open(settings_file) as f:
          s = json.load(f)
  s['customInstructions'] = skills_content
  with open(settings_file, 'w') as f:
      json.dump(s, f, indent=2)
  PYEOF

    rm "${SKILLS_TEMP}"
    echo "Skills injected from ${SKILLS_DIR}"
  fi
  ```

  > **Note on the Cline settings path:** The `customInstructions` field is how Cline exposes custom system prompt content. If the settings path or field name differs in your Cline version, open Cline in the browser → Settings → look for "Custom Instructions" and note where it's stored.

- [ ] **Step 3: Update Containerfile to create workspace directory and copy default skills**

  Append to `docker/Containerfile`:

  ```dockerfile

  # Create workspace directory structure
  USER root
  RUN mkdir -p /workspace/skills /workspace/code && \
      chown -R coder:coder /workspace
  USER coder

  # Copy default skills (can be overridden by mounting a local skills/ directory)
  COPY skills/ /workspace/skills/
  ```

- [ ] **Step 4: Build the image**

  ```bash
  podman build -t cloud-ide docker/
  ```

- [ ] **Step 5: Run and verify skills are injected**

  ```bash
  podman run -d --name cloud-ide-test -p 8080:8080 \
    -v ~/.aws:/home/coder/.aws:ro \
    -e AWS_REGION=us-west-2 \
    -e SPLUNK_MCP_URL=http://HOST_IP:PORT \
    -e SPLUNK_MCP_TOKEN=your-token \
    cloud-ide
  ```

  Check that skills were injected:

  ```bash
  podman exec cloud-ide-test cat \
    /home/coder/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings.json
  ```

  Expected: JSON containing a `customInstructions` field with the content of `splunk-basics.md`.

- [ ] **Step 6: Verify skills override works with a mounted directory**

  Stop the current container, then re-run with a local skills mount:

  ```bash
  podman rm -f cloud-ide-test

  podman run -d --name cloud-ide-test -p 8080:8080 \
    -v ~/.aws:/home/coder/.aws:ro \
    -v $(pwd)/docker/skills:/workspace/skills:ro \
    -e AWS_REGION=us-west-2 \
    -e SPLUNK_MCP_URL=http://HOST_IP:PORT \
    -e SPLUNK_MCP_TOKEN=your-token \
    cloud-ide
  ```

  Same verification as Step 5 — confirms the mount overrides the baked-in skills.

- [ ] **Step 7: Stop and remove**

  ```bash
  podman rm -f cloud-ide-test
  ```

- [ ] **Step 8: Commit**

  ```bash
  git add docker/Containerfile docker/entrypoint.sh docker/skills/splunk-basics.md
  git commit -m "feat: add skills"
  ```

---

## Final Verification

Run the complete container with all features:

```bash
podman run -d --name cloud-ide -p 8080:8080 \
  -v ~/.aws:/home/coder/.aws:ro \
  -v $(pwd)/docker/skills:/workspace/skills:ro \
  -e AWS_REGION=us-west-2 \
  -e SPLUNK_MCP_URL=http://HOST_IP:PORT \
  -e SPLUNK_MCP_TOKEN=your-token \
  cloud-ide
```

Checklist:
- [ ] VS Code loads at `http://localhost:8080`
- [ ] Cline extension visible and active
- [ ] Cline connects to Bedrock — send a test message and get a response
- [ ] MCP server listed as connected in Cline settings
- [ ] Cline responds using Splunk data when asked a relevant question
- [ ] Custom instructions contain skill content

To clean up:
```bash
podman rm -f cloud-ide
```
