# ECS Deployment Guide — LiteLLM Proxy Stack

This guide covers deploying the LiteLLM proxy stack on AWS ECS (Fargate), replacing the current Podman-based deployment on a Linux VM.

## Architecture Differences

| Component | Podman (Linux VM) | ECS (Fargate) |
|---|---|---|
| **Compute** | EC2 instance running Podman | Fargate tasks (serverless) |
| **Networking** | Podman bridge (`internal_net`) | VPC with Security Groups |
| **TLS** | nginx sidecar (self-signed cert) | ALB with ACM certificate |
| **Database** | Postgres container on same host | Postgres container (ECS) or Amazon RDS |
| **Secrets** | `.env` file on host | AWS Secrets Manager |
| **IAM** | EC2 instance role + IMDS | ECS Task Role (no IMDS) |
| **Egress** | `harden-egress.sh` (firewalld) | Security Groups (VPC-level) |
| **Persistence** | Local bind-mount volume | EFS or RDS |
| **Logs** | journald + `podman logs` | CloudWatch Logs |

## Prerequisites

### AWS Resources

1. **VPC** with at least 2 subnets across distinct AZs
2. **ECS Cluster** (Fargate)
3. **Application Load Balancer** with HTTP/HTTPS listeners
4. **ACM Certificate** for your domain (or use self-signed for testing)
5. **Secrets Manager** secrets:
   - `litellm/postgres-password`
   - `litellm/master-key`
6. **RDS instance** (recommended — provision via `rds-postgres.yaml` at the repo root; it's a VPC-level resource shared with the VM deployment path, not ECS-specific) OR **EFS Filesystem** (only if keeping containerized Postgres)
7. **IAM Roles**:
   - ECS Task Execution Role (pulls images, reads secrets)
   - ECS Task Role (Bedrock access)

### IAM Policies

**Task Role Policy** (attach to `ECS_TASK_ROLE_ARN`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:*::foundation-model/*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:*:*:secret:litellm/*"
    }
  ]
}
```

**Execution Role Policy** (attach to `ECS_EXECUTION_ROLE_ARN`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRPull",
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManagerRead",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:*:*:secret:litellm/*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/ecs/litellm:*"
    }
  ]
}
```

## Step 1: Deploy Security Groups

```bash
aws cloudformation deploy \
  --template-file ecs-security-groups.yaml \
  --stack-name litellm-ecs-sg \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    BedrockEndpointCidr=10.0.5.10/32 \
    AllowedCidr=10.0.0.0/16 \
    Environment=prod \
  --region us-east-1
```

Note the output Security Group IDs:

```bash
aws cloudformation describe-stacks \
  --stack-name litellm-ecs-sg \
  --query 'Stacks[0].Outputs'
```

## Step 2: Create Secrets in AWS Secrets Manager

```bash
# PostgreSQL password
aws secretsmanager create-secret \
  --name litellm/postgres-password \
  --secret-string "$(openssl rand -base64 32)"

# LiteLLM master key
aws secretsmanager create-secret \
  --name litellm/master-key \
  --secret-string "sk-$(openssl rand -hex 24)"
```

## Step 3: Create CloudWatch Log Group

```bash
aws logs create-log-group \
  --log-group-name /ecs/litellm \
  --region us-east-1
```

## Step 4: Push Images to ECR

ECS requires images in a registry accessible from your VPC (ECR recommended for private subnets).

```bash
# Create ECR repositories
aws ecr create-repository --repository-name litellm-proxy
aws ecr create-repository --repository-name litellm-db

# Get login token
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com

# Tag and push (from the project directory)
docker tag litellm-proxy:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/litellm-proxy:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/litellm-proxy:latest
```

## Step 5: Update compose-litellm-ecs.yaml

Set the environment variables and update the image references:

```bash
export AWS_REGION=us-east-1
export ECS_CLUSTER=litellm-cluster
export ECS_SUBNETS="subnet-aaa,subnet-bbb"
export ECS_SG_IDS="sg-0123456789abcdef0,sg-0123456789abcdef1"
export ECS_TASK_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskRole
export ECS_EXECUTION_ROLE_ARN=arn:aws:iam::<ACCOUNT_ID>:role/ecsTaskExecutionRole
export POSTGRES_PASSWORD=$(aws secretsmanager get-secret-value --secret-id litellm/postgres-password --query SecretString --output text)
export LITELLM_MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id litellm/master-key --query SecretString --output text)
```

## Step 6: Deploy to ECS

### Option A: Docker Compose with ECS Context

```bash
# Configure Docker for ECS
docker context create ecs litellm-ecs
docker context use litellm-ecs

# Deploy
docker compose --file compose-litellm-ecs.yaml up
```

### Option B: AWS Copilot (recommended for production)

```bash
copilot init --name litellm --dockerfile litellm_service/Dockerfile
copilot deploy
```

### Option C: Manual ECS CLI

```bash
ecs-cli compose --file compose-litellm-ecs.yaml service up
```

## Step 7: Configure ALB Target Groups

1. Create a target group for port 4000 (litellm-proxy)
2. Create an ALB listener rule for port 443 → target group
3. Create an ALB listener rule for port 80 → redirect to 443

## Step 8: Update Client Configuration

Point clients to the ALB DNS name:

```bash
# Claude Code CLI
export ANTHROPIC_BASE_URL="https://litellm.your-domain.com"
export ANTHROPIC_API_KEY="sk-generated-user-token"

# VS Code
# Base URL: https://litellm.your-domain.com/v1
# API Key: sk-generated-user-token
```

## Security Comparison

| Control | Podman (harden-egress.sh) | ECS (Security Groups) |
|---|---|---|
| **Bypassable?** | Yes — a root process on the host can modify firewalld rules | No — enforced by VPC fabric, cannot be modified from inside the task |
| **Scope** | Only affects traffic from the Podman bridge subnet | Affects all traffic from the task's ENI |
| **Portability** | Tied to this specific RHEL host and firewalld | Works in any VPC, any region, any account |
| **Auditable** | Manual `firewall-cmd --list-all` | AWS Config, CloudTrail, Security Group flow logs |
| **Credential scope** | IMDS credentials scoped to EC2 instance | Task Role credentials scoped to task lifetime |

## Troubleshooting

### Task fails to start

```bash
aws ecs describe-services --cluster litellm-cluster --services litellm-proxy
# Check stopped tasks for error messages
aws ecs list-tasks --cluster litellm-cluster --desired-status STOPPED
aws ecs describe-tasks --cluster litellm-cluster --tasks <task-arn>
```

### Cannot reach Bedrock

1. Verify the Bedrock VPC endpoint exists and is in the same subnets
2. Check the `LitellmProxySecurityGroup` egress rules allow TCP 443 to the endpoint CIDR
3. Verify the Task Role has `bedrock:InvokeModel` permission

### Database connection refused

1. Verify `litellm-db` task is running and healthy
2. Check the `LitellmDbSecurityGroup` ingress allows TCP 5432 from `LitellmProxySecurityGroup`
3. Verify `DATABASE_URL` uses the correct hostname (ECS service name or RDS endpoint)

### Logs not appearing

1. Check the CloudWatch log group `/ecs/litellm` exists
2. Verify the Execution Role has `logs:PutLogEvents` permission
3. Check the `awslogs` configuration in the task definition
