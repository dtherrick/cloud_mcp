# Cloud IDE POC Design: VS Code + Cline + Splunk MCP on AWS

## Context

This is a proof-of-concept to demonstrate that a cloud-hosted VS Code IDE with agentic AI (Cline), MCP server integration (Splunk), and a skills system can be built and run on AWS. The primary deliverable is a working Docker image and minimal Terraform that the Splunk Show team can integrate into their existing AWS environment. Auth and routing are out of scope — the Show environment handles those.

---

## Goals

- Demonstrate VS Code (code-server) running in a browser, hosted on AWS
- Demonstrate Cline making agentic AI calls via Amazon Bedrock (Claude)
- Demonstrate Cline using the Splunk MCP server to query/interact with Splunk
- Demonstrate a skills system where markdown/config files guide agent behavior
- Produce clean, readable Terraform that the Show team can adapt

## Non-Goals

- Multi-tenant workspace orchestration (not needed for POC)
- Auth/identity (handled by Show environment)
- ALB routing, Cognito, Route 53 (handled by Show environment)
- Production hardening, SLAs, monitoring dashboards

---

## Architecture

### Overview

```
[Browser]
    |
    v
[ECS Fargate Task]
    └── code-server container     (VS Code in browser, port 8080)
             |
        [Cline extension]
             |  spawns subprocess
        [npx mcp-remote]          (stdio MCP client → HTTP bridge)
             |
             v (HTTPS, bearer token, out via VPC NAT or endpoint)
        [Splunk MCP HTTP endpoint]
             |
        [Cline extension]
             |
             v (VPC endpoint)
        [Amazon Bedrock]
```

The ECS Fargate task is a single container. Cline spawns `npx mcp-remote` as a child process directly — no sidecar needed. This is simpler, matches how the Splunk MCP config already works locally, and eliminates inter-container coordination complexity.

Workspace files persist on an EFS volume mounted into the container. When the task stops and restarts, the user's files are still there.

---

## Components

### 1. Docker Image: `cloud-ide`

Built on `codercom/code-server` (pinned version). Contains:

- code-server (VS Code in browser)
- Cline VS Code extension (installed at image build time from `.vsix`)
- Skills loader (a startup script that reads skill files from `/workspace/skills/` and makes them available to Cline via VS Code settings or a config file)
- code-server config with auth disabled (Show environment handles auth)
- MCP client config pointing to the Splunk MCP sidecar on `localhost`

**Cline MCP config (baked into image, URL/token overridden at runtime via env vars):**
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

### 2. Splunk MCP Process

Cline spawns `npx mcp-remote` as a child process (stdio transport) within the code-server container. No separate sidecar container is needed — this matches exactly how the Splunk MCP config works in local development.

`mcp-remote` is not pre-installed in the image; `npx -y` fetches and caches it on first use. Node.js must be available in the container (code-server base image includes it).

Runtime config injected via ECS task environment variables (substituted into `cline-mcp.json` at container startup by the entrypoint script):
- `SPLUNK_MCP_URL` — URL of the Splunk MCP HTTP endpoint
- `SPLUNK_MCP_TOKEN` — Bearer token for Splunk auth

Both values are stored in AWS Secrets Manager and injected at task launch time.

**Outbound connectivity note:** `mcp-remote` calls the Splunk MCP HTTP endpoint over HTTPS. Since Splunk runs outside AWS, this traffic must exit the VPC. Options: NAT Gateway in the public subnet (simplest, adds ~$32/mo), or if the Show environment's VPC already has a NAT Gateway, deploy into that VPC instead of creating a new one.

### 3. Skills System

Skills are markdown files that live in `/workspace/skills/` on the EFS volume. At container startup, the entrypoint script reads these files and injects them into Cline's system prompt or custom instructions config.

For the POC, a small set of starter skills demonstrating Splunk-specific agent behavior will be included (e.g., "how to query Splunk data", "how to interpret SPL results").

The Show team or end users can add/edit skill files directly in VS Code — they persist on EFS.

### 4. EFS Volume

One EFS filesystem, one access point per workspace. Mount layout:

```
/workspace/
├── code/          # user project files
├── skills/        # skill markdown files
├── mcp-config/    # MCP configuration (if user-editable)
└── .vscode/       # VS Code settings and extension state
```

For the POC, a single access point is sufficient. Multi-user expansion is a Show team concern.

### 5. Amazon Bedrock

Cline calls Bedrock via a VPC interface endpoint — traffic never leaves AWS. The ECS task IAM role grants `bedrock:InvokeModel` scoped to the allowed model IDs (Claude Sonnet/Haiku).

**Prerequisites:** Bedrock model access must be explicitly enabled in the AWS console for the target region before deployment. Navigate to Bedrock → Model access → Request access for Claude Sonnet and/or Haiku. This is a one-time manual step that cannot be automated via Terraform.

### 6. Terraform Infrastructure

Minimal Terraform producing:

- VPC with public + private subnets (2 AZs)
- NAT Gateway in public subnet (for outbound HTTPS to Splunk MCP endpoint)
- VPC interface endpoints: Bedrock, ECR, ECS, EFS, CloudWatch Logs
- S3 gateway endpoint (free, for ECR layer pulls)
- EFS filesystem + access point
- ECR repository for the `cloud-ide` image
- ECS cluster + task definition (single code-server container)
- ECS service (1 task, for POC)
- IAM roles: task execution role, task role (Bedrock + EFS + Secrets Manager)
- Secrets Manager secrets: `SPLUNK_MCP_URL`, `SPLUNK_MCP_TOKEN`
- Security groups: workspace task SG (inbound 8080 from Show ALB SG), EFS SG

The Terraform is intentionally minimal — no lifecycle automation, no workspace control plane. The Show team's ALB points at the ECS service's task on port 8080.

If deploying into Show's existing VPC (recommended), the VPC and NAT Gateway resources are omitted from the Terraform and replaced with `data` sources referencing existing infrastructure.

---

## Data Flow: Agent Interaction

1. User opens `{workspace}.ide.showenv.splunk.com` in browser (Show ALB handles routing)
2. VS Code loads in browser via code-server
3. User types a request in Cline (e.g., "Show me the top 10 errors in the last hour")
4. Cline sends the request + skills context to Bedrock (Claude) via VPC endpoint
5. Claude responds with a tool call to `splunk-mcp-server`
6. Cline invokes the `mcp-remote` child process via stdio
7. `mcp-remote` calls the Splunk MCP HTTP endpoint with the bearer token
8. Splunk returns results; `mcp-remote` returns them to Cline via stdio
9. Claude synthesizes the results and responds to the user in VS Code

---

## Security Considerations (POC scope)

- No credentials hardcoded in image — all secrets via AWS Secrets Manager + ECS secrets injection
- Bedrock traffic stays in VPC via interface endpoint
- code-server auth disabled intentionally — Show environment enforces access control
- Task IAM role follows least privilege: only Bedrock invoke, EFS mount, and Secrets Manager read
- EFS only accessible from within the VPC (no public mount target)

---

## Terraform Module Structure

```
terraform/
├── main.tf           # provider, backend config
├── variables.tf      # splunk_mcp_url, splunk_mcp_token, aws_region, etc.
├── outputs.tf        # ECS service ARN, ECR repo URL, EFS ID
├── vpc.tf            # VPC, subnets, VPC endpoints, security groups
├── efs.tf            # EFS filesystem, mount targets, access point
├── iam.tf            # task execution role, task role, policies
├── ecr.tf            # ECR repository
├── ecs.tf            # cluster, task definition, service
└── secrets.tf        # Secrets Manager secrets for Splunk MCP credentials
```

---

## Docker Image Structure

```
docker/
├── Dockerfile
├── entrypoint.sh          # sets up workspace dirs, injects skills, starts code-server
├── config/
│   ├── code-server.yaml   # code-server config (port, auth: none)
│   └── cline-mcp.json     # MCP client config template (env var substitution at startup)
└── skills/
    └── splunk-basics.md   # starter skill: how to work with Splunk via MCP
```

---

## Open Questions for Show Team

1. What security group ID does the Show ALB use? (needed for workspace task SG ingress rule)
2. What VPC should this deploy into — Show's existing VPC or a new one?
3. Should the Terraform use an existing S3 backend, or is local state fine for POC?
4. What IAM constraints exist in the Show AWS account? (affects VPC endpoint and EFS creation)
5. Will the Splunk MCP token be rotated? If so, how frequently — informs Secrets Manager rotation setup.

---

## Handoff Artifacts

- `docker/` — Dockerfile and supporting files to build the `cloud-ide` image
- `terraform/` — Terraform modules to deploy the infrastructure
- `docs/` — this spec + a README with deployment instructions
- A working demo showing the Cline → Bedrock → Splunk MCP end-to-end flow
