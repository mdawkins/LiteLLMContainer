# Security Remediation Plan — Response to Cyber Security's Supply-Chain Concerns

Meeting prep for the design review with Chief AI Officer, AWS architects, and Cyber Security. Structured to map directly onto the threat model Cyber Security raised (see `CyberSecurityConcerns.md`), not to re-argue the original email.

## Opening framing

Open with this, verbatim if useful:

> "Cyber Security's reference to the March PyPI supply chain attack is completely valid. While our architecture prevents static API keys from being stolen out of a database, a compromised Python dependency running inside the container could still attempt to query our AWS IMDS endpoint or exfiltrate runtime data. We need to design around runtime and dependency security, not just storage security."

Then move straight to the table below — the goal is to show the threat model was heard and is already being engineered against, not defended against.

## Threat vector → control mapping

| Threat vector (Cyber Security's concern) | Control | Status |
|---|---|---|
| `litellm-proxy` on the host network gives a compromised dependency direct access to the host's entire network interface and unrestricted IMDS reach | Proxy runs on an isolated Podman bridge network (`internal_net`), not `network_mode: host` — confirmed live via `podman inspect` (`NetworkMode: bridge`) | **Already in place.** (Was true in an earlier revision; docs describing `network_mode: host` were stale and are being corrected this week — see note below.) |
| Poisoned dependency shipped via a floating/mutable tag (exactly how the March attack landed — `pip install litellm` with no pin) | All three images (`litellm`, `postgres`, `nginx`) pinned to immutable `sha256` digests instead of `main-latest`/`18`/`alpine`; digest bumps are a deliberate, reviewed action, never an automatic pull | **In progress this week** |
| Compromised container "calls home" to an external C2 server (e.g. `models.litellm.cloud`) | `harden-egress.sh` — firewalld policy scoped to the proxy's bridge subnet: allow only DNS + IMDS + Bedrock, reject all other outbound. Written and ready; deliberately not auto-run since the Bedrock destination depends on the open question below | **Script ready; needs AWS architect input to run it** — see open question below |
| Stolen short-lived IMDS/IAM credentials replayed from outside our network | IMDSv2 enforcement (`HttpTokens=required`) with `HttpPutResponseHopLimit=2`; IAM role scoped with `aws:SourceVpce`/`aws:SourceIp` condition keys so a stolen token can't be used off-box | **Needs AWS architect input** (IAM/EC2 instance metadata options — outside this repo, needs their sign-off) |
| No visibility into what's actually in the deployed image before it ships | `.github/workflows/image-scan.yml` builds both images and runs a Trivy vulnerability + Dockerfile-misconfiguration scan, gating on unfixed CRITICAL/HIGH CVEs, plus an SPDX SBOM artifact per build | **In progress this week** |
| Even with network/dependency controls, a fully compromised proxy process has more privilege than it needs | Rootless Podman (existing) + Linux capabilities dropped (`cap_drop: ALL`) + `no-new-privileges` on the proxy and nginx containers | **In progress this week** |

## Note on the stale-docs finding

Internal review this week found that `README.md`/setup docs still described the proxy as `network_mode: host` reaching IMDS over the host network — that was true in an earlier revision but the compose file was already changed to bridge-network isolation. Docs are being corrected to match the deployed reality. Raising this proactively: it's the same category of issue Cyber Security flagged in the original thread (claims not matching how the app actually operates), and getting ahead of it here is deliberate.

## Open questions for the meeting

1. **Egress control mechanism** — does this VPC have (or can it get) a Bedrock VPC interface endpoint? That turns the egress rule into "only the endpoint ENI + IMDS," which doesn't rot as AWS's public IP ranges change. If not feasible, fallback is firewalld allow-listing against AWS's published Bedrock IP ranges, reviewed on a recurring cadence.
2. **IMDS hop limit** — `HttpPutResponseHopLimit` on the production EC2 instance needs to be set to `2`, not left at the IMDSv2 default of `1`. Since the proxy now runs on the `internal_net` bridge (not `network_mode: host`), its metadata requests traverse an extra NAT hop; at the default hop limit of `1` those requests are silently dropped and credential fetch fails outright. This isn't just a hardening nicety — get it wrong and Bedrock auth breaks in production. (Verified the failure mode on this dev box, which turned out to be a local VirtualBox VM rather than real EC2, so an on-EC2 confirmation is still needed — see AWS architects.)
3. **Scanner preference** — does Cyber Security want a specific tool in the CI gate (Trivy is proposed; Snyk is a common alternative) so the pipeline satisfies their audit requirements on day one rather than needing rework later.
4. **CI runner environment** — the proposed workflow (`.github/workflows/image-scan.yml`) assumes GitHub-hosted runners with outbound access to ghcr.io/Docker Hub. Given this is a federal/NHTSA environment, confirm whether CI needs to run on self-hosted runners or through an internal registry mirror instead.
5. **ECS/EKS migration** — this remediation targets the current EC2+Podman deployment. If/when the stack moves to ECS or EKS, the credential path changes (ECS task roles via the task metadata endpoint, or EKS IRSA via OIDC) and none of the IMDS/hop-limit guidance above will apply as-is — flagging this now so it isn't a surprise later, but it's out of scope for this week's remediation.

## Bottom line

The foundation (rootless containers, IAM-role-based auth, no static keys) was already sound. This closes the gap between that foundation and the specific supply-chain and runtime-execution threat Cyber Security raised: pinned images, restricted egress, hardened IMDS, capability-dropped containers, and an auditable scan pipeline. Bring the AWS architects in on the two open items above and this should clear the ATO review.
