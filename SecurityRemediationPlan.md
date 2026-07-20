# Security Remediation Plan — Response to Cyber Security's Supply-Chain Concerns

Meeting prep for the design review with Chief AI Officer, AWS architects, and Cyber Security. Structured to map directly onto the threat model Cyber Security raised (see `CyberSecurityConcerns.md`), not to re-argue the original email.

## Opening framing

Open with this, verbatim if useful:

> "Cyber Security's reference to the March PyPI supply chain attack is completely valid. While our architecture prevents static API keys from being stolen out of a database, a compromised Python dependency running inside the container could still attempt to query our AWS IMDS endpoint or exfiltrate runtime data. We need to design around runtime and dependency security, not just storage security."

Then move straight to the table below — the goal is to show the threat model was heard and is already being engineered against, not defended against.

## Real-world validation — this is not a hypothetical

Cyber Security's March 2026 reference is a documented, named incident, not a generic CVE feed hit: [Trend Micro, "Inside the LiteLLM Supply Chain Compromise"](https://www.trendmicro.com/en_us/research/26/c/inside-litellm-supply-chain-compromise.html). Threat actors ("TeamPCP") poisoned LiteLLM's official PyPI releases (`v1.82.7`, `v1.82.8`) with `.pth` files that executed on Python interpreter startup — no `import litellm` required. The payload scanned for environment variables, SSH keys, cloud credentials, and Kubernetes tokens, then exfiltrated them to an external C2 (`models.litellm.cloud`). This confirms two things directly relevant to our deployment:

- **Organizations running official, digest-pinned container images were not affected** — this is the single strongest argument for the digest-pinning control already in the threat table below, and it's not a theoretical benefit; it's the documented difference between "compromised" and "not compromised" in this exact incident.
- **The earlier claim that "credential exfiltration risk is functionally zero" was wrong, and we're retracting it here rather than in a follow-up email.** That claim was scoped to static database credential theft (SQL injection, stored secrets) and didn't account for application-layer/dependency compromise reaching live process memory, environment variables, and the IMDS-derived AWS session in real time. Cyber Security's pushback on that point was correct.

## Threat vector → control mapping

| Threat vector (Cyber Security's concern) | Control | Status |
|---|---|---|
| `litellm-proxy` on the host network gives a compromised dependency direct access to the host's entire network interface and unrestricted IMDS reach | Proxy runs on an isolated Podman bridge network (`internal_net`), not `network_mode: host` — confirmed live via `podman inspect` (`NetworkMode: bridge`) | **Already in place.** (Was true in an earlier revision; docs describing `network_mode: host` were stale and are being corrected this week — see note below.) |
| Poisoned dependency shipped via a floating/mutable tag (exactly how the March attack landed — `pip install litellm` with no pin) | All three images (`litellm`, `postgres`, `nginx`) pinned to immutable `sha256` digests instead of `main-latest`/`18`/`alpine`; digest bumps are a deliberate, reviewed action, never an automatic pull | **In progress this week** |
| Compromised container "calls home" to an external C2 server (e.g. `models.litellm.cloud`) | `harden-egress.sh` — firewalld policy scoped to the proxy's bridge subnet: allow only DNS + IMDS + Bedrock, reject all other outbound. Written and ready; deliberately not auto-run since the Bedrock destination depends on the open question below | **Script ready; needs AWS architect input to run it** — see open question below |
| Stolen short-lived IMDS/IAM credentials replayed from outside our network | IMDSv2 enforcement (`HttpTokens=required`) with `HttpPutResponseHopLimit=2`; IAM role scoped with `aws:SourceVpce`/`aws:SourceIp` condition keys so a stolen token can't be used off-box | **Needs AWS architect input** (IAM/EC2 instance metadata options — outside this repo, needs their sign-off) |
| No visibility into what's actually in the deployed image before it ships | `scan-image.sh` — scanner-agnostic image scan (vuln gate on unfixed CRITICAL/HIGH + optional Dockerfile-misconfig check + SPDX SBOM). Backend is swappable (`SCANNER=trivy\|grype\|custom`); Trivy is only the default, not a requirement. Run manually today: `./scan-image.sh --image <ref>`. `.github/workflows/image-scan.yml` shows one possible CI wiring but is **not enabled** — see the CI/CD note below | **Script in place; not gated by any running CI/CD** |
| Even with network/dependency controls, a fully compromised proxy process has more privilege than it needs | Rootless Podman (existing) + Linux capabilities dropped (`cap_drop: ALL`) + `no-new-privileges` on the proxy and nginx containers | **In progress this week** |
| LiteLLM is a centralized gateway: every user's Bedrock routing, the master key, and the AWS IAM role all pass through one process. A compromise of that process — not any individual user's key — is a single point that exposes everything in flight, which is exactly what makes it a high-value target | Per-user API keys with independent budgets/rate limits and revocation (`create-ai-user.sh`/`check-ai-user.sh`/`revoke-ai-user.sh`) limit the blast radius of *one stolen user key*. They do **not** limit the blast radius of the gateway process itself being compromised — that process can still see every in-flight request and holds the master key and Bedrock-scoped AWS session directly | **Open structural risk. Network/image/capability controls above reduce the odds of compromise; they don't eliminate the concentration itself. This is a risk-acceptance and telemetry question for Cyber Security, not something config alone resolves — see below** |

## Telemetry and runtime monitoring — the gap the static controls above don't close

Every control above is a *static* defense: it's set once (network isolation, image digests, capability drops) and doesn't tell anyone when something's actually gone wrong at runtime. That's the piece still missing, and it's the direct answer to "this needs sophisticated configuration and telemetry hooks to be secure":

- **No runtime anomaly detection.** `harden-egress.sh` blocks unexpected outbound connections but doesn't alert on blocked *attempts* — a live indicator of compromise today would show up only as a line in `firewalld`'s own log, not a signal anyone is watching.
- **No AWS-side telemetry wired to this workload.** GuardDuty (anomalous IMDS credential use, unusual API call patterns from the assumed role) and Security Hub are not enabled/scoped to this instance or role. This is the most direct way to detect a TeamPCP-style compromise in progress — a container abusing IMDS to mint Bedrock calls at 2am looks very different from normal traffic, but only if something is watching for it.
- **SBOM/scanning is point-in-time, not continuous.** `scan-image.sh` catches known-vulnerable dependencies at scan time; it does not re-check already-deployed, pinned images against newly disclosed CVEs after the fact. A dependency pinned as "clean" today can have a CVE disclosed against it next week with nothing re-flagging it.
- **No centralized audit log review.** LiteLLM's own Postgres-backed usage/budget tracking (via `litellm-db`) records key usage, but nothing currently ships those logs to a SIEM or triggers an alert on anomalous patterns (e.g., one key suddenly issuing requests at 50x its historical rate).

None of this is fully specifiable from our side alone — it depends on what Cyber Security already has standing (GuardDuty/Security Hub org-wide enablement, a SIEM ingestion point, log retention requirements) versus what would need to be stood up new for this workload. This is the concrete "what telemetry do you want" question to bring to the meeting, not a rhetorical one.

## Note on CI/CD status

**CI/CD is not implemented for this repo.** `.github/workflows/image-scan.yml` is a drafted reference example — it has never been enabled against a real pipeline, and its presence in the tree should not be read as "the scan gate is running." The actual scan logic lives in `scan-image.sh`, which is runnable manually or from any CI system once one is stood up, and does not assume Trivy specifically (see open question #3 below).

## Note on the stale-docs finding

Internal review this week found that `README.md`/setup docs still described the proxy as `network_mode: host` reaching IMDS over the host network — that was true in an earlier revision but the compose file was already changed to bridge-network isolation. Docs are being corrected to match the deployed reality. Raising this proactively: it's the same category of issue Cyber Security flagged in the original thread (claims not matching how the app actually operates), and getting ahead of it here is deliberate.

## Open questions for the meeting

1. **Egress control mechanism** — does this VPC have (or can it get) a Bedrock VPC interface endpoint? That turns the egress rule into "only the endpoint ENI + IMDS," which doesn't rot as AWS's public IP ranges change.
   **Update (2026-07-20): the public-IP fallback doesn't actually exist as originally assumed.** Checked `ip-ranges.json` directly — AWS does not publish a `BEDROCK`-tagged service entry at all. Bedrock's regional endpoints resolve into the generic `AMAZON` catch-all, which for `us-east-1` alone is **840 separate CIDR blocks** — effectively all of AWS's public IP footprint in that region, not a Bedrock-specific list. Allow-listing that is barely a restriction: it blocks non-AWS-hosted C2 but does nothing against C2 hosted on rented AWS infrastructure (EC2/Lightsail), which is a well-known technique specifically because "allow AWS" egress rules are common and weak. **This changes the ask to the architects: the VPC endpoint is now a hard requirement for this control to mean anything, not a preference with a workable fallback.** If a firewalld interim is deployed anyway (see `harden-egress.sh` `BEDROCK_PUBLIC_CIDRS`), it must be documented as a weak, temporary stopgap — not as satisfying the "killer control" bar this remediation item was written for.
2. **IMDS hop limit** — `HttpPutResponseHopLimit` on the production EC2 instance needs to be set to `2`, not left at the IMDSv2 default of `1`. Since the proxy now runs on the `internal_net` bridge (not `network_mode: host`), its metadata requests traverse an extra NAT hop; at the default hop limit of `1` those requests are silently dropped and credential fetch fails outright. This isn't just a hardening nicety — get it wrong and Bedrock auth breaks in production. (Verified the failure mode on this dev box, which turned out to be a local VirtualBox VM rather than real EC2, so an on-EC2 confirmation is still needed — see AWS architects.)
3. **Scanner preference** — `scan-image.sh` makes the scanner backend swappable (`SCANNER=trivy|grype|custom`), so this is no longer "which tool to hardcode." It's now: does Cyber Security's audit process expect a specific default (Trivy, Snyk, or another org-standard tool) so docs and the reference workflow point at that tool from day one, rather than an arbitrary default needing rework later.
4. **CI runner environment** — no CI/CD pipeline is implemented yet (see the note above). The unenabled reference workflow (`.github/workflows/image-scan.yml`) assumes GitHub-hosted runners with outbound access to ghcr.io/Docker Hub, which is one option among several. Given this is a federal/NHTSA environment, confirm whether CI needs to run on self-hosted runners or through an internal registry mirror instead — this decision blocks enabling any CI/CD, not just this specific workflow.
5. **ECS/EKS migration** — this remediation targets the current EC2+Podman deployment. If/when the stack moves to ECS or EKS, the credential path changes (ECS task roles via the task metadata endpoint, or EKS IRSA via OIDC) and none of the IMDS/hop-limit guidance above will apply as-is — flagging this now so it isn't a surprise later, but it's out of scope for this week's remediation.

## ECS Migration (target environment)

Open question #5 in the table above flagged that the current remediation targets the EC2+Podman deployment. Since the true target is ECS, the following controls replace or supersede the Podman-specific ones:

### Credential path — ECS Task Roles replace IMDS

| EC2+Podman | ECS (Fargate) |
|---|---|
| `litellm-proxy` runs on bridge network, reaches IMDS (`169.254.169.254`) via NAT hop. Requires `HttpPutResponseHopLimit >= 2`. | Tasks assume an ECS Task Role. boto3 picks up credentials from `AWS_CONTAINER_CREDENTIALS_FULL_URI` (the task metadata endpoint at `169.254.170.2`). No IMDS, no hop-limit, no host network. |
| Compromised dependency can query IMDS directly from inside the container. | Task Role credentials are scoped to the task's lifetime and IAM policy. No ambient credentials leak to the host. |

**Action**: Define an `ECS_TASK_ROLE_ARN` with a policy that allows only `bedrock:InvokeModel` and (if using Secrets Manager) `secretsmanager:GetSecretValue` scoped to the `litellm/*` secret ARNs. The role must NOT have broad `sts:AssumeRole` or `ec2:Describe*`.

### Egress filtering — Security Groups replace firewalld

| EC2+Podman (`harden-egress.sh`) | ECS (Security Groups) |
|---|---|
| `firewall-cmd` policies scoped to the Podman bridge subnet. Requires root, runs on the host, and is non-portable. | Security Groups attached to each task's ENI. Enforced by the VPC fabric — non-bypassable from inside the task, even by a fully compromised process. |
| Bedrock destination is an open question (VPC endpoint vs public IP allow-list) — and the public IP allow-list fallback is weaker than originally assumed; see open question #1 above. | Security Group `LitellmProxySecurityGroup` in `ecs-security-groups.yaml` allows outbound TCP 443 only to the Bedrock VPC endpoint CIDR (or fallback public ranges). |

**Action**: Deploy `ecs-security-groups.yaml` via CloudFormation. Set `BedrockEndpointCidr` to your VPC endpoint ENI CIDR (preferred — and now effectively required, see open question #1) or `BedrockPublicCidrs` to the published ranges as an interim, explicitly weak stopgap. The `LitellmDbSecurityGroup` has **zero egress** — Postgres cannot call home.

### Network isolation — VPC replaces Podman bridge

| EC2+Podman | ECS |
|---|---|
| All three containers share `internal_net` bridge. `litellm-db` also binds `127.0.0.1:5432`. | Each task gets an ENI in your VPC subnets. Inter-service communication is via Security Groups, not bridge DNS. `litellm-db` is reachable only from `litellm-proxy`. |

### Secrets management — AWS Secrets Manager replaces .env

| EC2+Podman | ECS |
|---|---|
| `POSTGRES_PASSWORD` and `LITELLM_MASTER_KEY` in `.env` (generated by `gen-env.sh`). | Store in AWS Secrets Manager (`litellm/postgres-password`, `litellm/master-key`). Reference via `secrets:` in the ECS task definition or inject as environment variables via the ECS integration. |

### Persistence — Amazon RDS is now a concrete option for BOTH targets, not just ECS

RDS is a VPC-level resource, not compute-specific — it's just as reachable from the EC2 VM as from an ECS task, so this is no longer framed as an ECS-only migration step. `rds-postgres.yaml` (repo root) provisions it; `compose-litellm.yaml`'s `litellm-proxy` reads `DATABASE_URL` from `.env` either way, so switching is a config change, not a rebuild.

**Where RDS's isolation actually comes from — it is NOT on `internal_net`.** RDS gets its own ENI in your VPC subnets; it is never a member of the Podman bridge network (or, on ECS, the task's network). Isolation is enforced by the `RdsSecurityGroup` (ingress on 5432 restricted to the client's own security group, or a fallback CIDR) plus `PubliclyAccessible: false` — the same VPC-fabric guarantee already described for `ecs-security-groups.yaml`, not container-network membership.

| EC2+Podman (default) | Either target, with RDS |
|---|---|
| `litellm-db` container, `${VOLUMES}/litellm_pgvol/data/` local directory. Manual backups, no encryption at rest unless the EBS volume itself is encrypted. | `rds-postgres.yaml` provisions an encrypted, non-publicly-accessible instance with automated backups. `litellm-db` container is commented out; `DATABASE_URL` in `.env` points at the RDS endpoint. IAM database authentication is exposed as an option on the instance but **not wired up** — token refresh needs RDS Proxy or a sidecar (15-minute token expiry), flagged as a future open question rather than a working feature today. |

On ECS specifically, this also means the `litellm-db` task and its EFS dependency go away entirely once RDS is adopted — one less task to run, patch, and secure.

### Updated threat vector → control mapping (ECS)

| Threat vector | EC2+Podman control | ECS control |
|---|---|---|
| Compromised dependency queries IMDS | Bridge network + hop-limit | Task Role (no IMDS access) |
| Compromised container calls home to C2 | `harden-egress.sh` (firewalld) | Security Group egress rules (VPC-level) |
| Stolen credentials replayed from outside | IMDSv2 + IAM conditions | Task Role scoped to VPC; credentials expire at task stop |
| Poisoned dependency via floating tag | Digest-pinned images | Same (digest pinning) |
| No visibility into image contents | `scan-image.sh` (scanner-agnostic) + SBOM, run manually — no CI/CD gate exists yet | Same, once a CI/CD pipeline is stood up |
| Excess privilege in container | Rootless + cap_drop + no-new-privileges | Same + Fargate (no host OS to escape to) |
| Key concentration — gateway compromise exposes every in-flight credential | Per-user budgets/revocation limit single-key blast radius; gateway-level compromise is not eliminated by either target | Same open structural risk; Task Role scoping narrows what a compromised task can reach, but does not remove the single-gateway concentration itself |

### ECS-specific open items

1. **Bedrock VPC endpoint** — still needed. Deploy a VPC interface endpoint for `com.amazonaws.us-east-1.bedrock-runtime` in the same subnets as the ECS tasks. The Security Group `LitellmProxySecurityGroup` should reference this endpoint's CIDR.
2. **RDS vs self-managed Postgres** — recommended for both targets now that `rds-postgres.yaml` exists; if migrating, the `litellm-db` task/container is removed entirely and `DATABASE_URL` points to the RDS endpoint. RDS provides encryption at rest and automated backups out of the box; IAM authentication is available on the instance but not wired into litellm-proxy yet (needs RDS Proxy or a token-refresh sidecar — separate follow-up).
3. **ALB vs nginx sidecar** — the compose file comments out `litellm-nginx`. ALB handles TLS termination, HTTP→HTTPS redirect, and health checks. If you need a specific nginx feature (e.g., custom header injection, mTLS), uncomment the nginx sidecar.
4. **Scanner preference** — same open question as #3 in the original plan; `scan-image.sh` supports Trivy, Grype, or a custom command either way.
5. **CI runner environment** — same as #4 in the original plan; no CI/CD is implemented for either target yet.

## Bottom line

The foundation (rootless containers, IAM-role-based auth, no static keys) was already sound, but the "credential exfiltration risk is functionally zero" framing was not — this plan retracts that, names the March 2026 TeamPCP/PyPI incident as direct validation of Cyber Security's concern, and treats LiteLLM's centralized-gateway design as a real structural risk, not a solved one. What's engineered so far — pinned images, restricted egress, hardened IMDS, capability-dropped containers, a scanner-agnostic scan script — are all *static* controls, and they don't fully answer the concentration-of-keys problem or give anyone runtime visibility into whether a compromise is happening right now. That's genuinely still open, and closing it needs both Cyber Security's input on required telemetry (GuardDuty/Security Hub/SIEM scope) and AWS architects' input on Bedrock VPC endpoints, IAM condition scoping, and RDS. Two things are explicitly **not** done yet and shouldn't be represented as done: a running CI/CD pipeline (only a manual script + an unenabled reference workflow exist), and an actual RDS deployment (the template exists; nothing has been provisioned). The ECS migration eliminates the IMDS hop-limit problem entirely (Task Roles) and replaces firewalld with VPC-level Security Groups (non-bypassable), but does not eliminate the key-concentration risk either. Bring Cyber Security in as a partner on telemetry requirements and AWS architects in on the Bedrock VPC endpoint/RDS decisions, and this has a real path to ATO — but only if the meeting opens with alignment, not a repeat of the "risk is zero" position.
