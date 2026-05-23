 Alchemyst AI — DevOps Internship Assignment
## Distributed Inference System on AWS

---

## Architecture Overview

```
                        Internet
                            │
                    HTTPS / HTTP :3111
                            │
                    ┌───────▼────────┐
                    │ Internet Gateway│
                    │     (IGW)       │
                    └───────┬────────┘
                            │
          ┌─────────────────▼──────────────────────┐
          │           AWS VPC (10.0.0.0/16)         │
          │                                         │
          │  ┌──────────────────────────────────┐   │
          │  │    Public Subnet (10.0.1.0/24)   │   │
          │  │    Route: 0.0.0.0/0 → IGW        │   │
          │  │                                  │   │
          │  │  ┌─────────────┐  ┌───────────┐  │   │
          │  │  │ API Gateway │  │  Bastion  │  │   │
          │  │  │     VM      │  │  Host VM  │  │   │
          │  │  │ t3.small    │  │ t3.micro  │  │   │
          │  │  │─────────────│  │───────────│  │   │
          │  │  │iii engine   │  │SSH :22    │  │   │
          │  │  │ws://:49134  │  │(your IP   │  │   │
          │  │  │caller-worker│  │ only)     │  │   │
          │  │  │HTTP :3111   │  │           │  │   │
          │  │  │PUBLIC IP    │  │PUBLIC IP  │  │   │
          │  │  └──────┬──────┘  └───────────┘  │   │
          │  │         │   NAT Gateway           │   │
          │  │         │   + Elastic IP          │   │
          │  └─────────│────────────────────────┘   │
          │            │ WebSocket RPC :49134        │
          │  ┌─────────▼──────────────────────────┐  │
          │  │   Private Subnet (10.0.2.0/24)     │  │
          │  │   Route: 0.0.0.0/0 → NAT GW        │  │
          │  │                                    │  │
          │  │  ┌──────────────────────────────┐  │  │
          │  │  │     Inference Worker VM      │  │  │
          │  │  │         t3.medium            │  │  │
          │  │  │──────────────────────────────│  │  │
          │  │  │ inference-worker (Python)    │  │  │
          │  │  │ gemma-3-270m model           │  │  │
          │  │  │ SG: port 49134 (API GW only) │  │  │
          │  │  │ SG: port 22 (bastion only)   │  │  │
          │  │  │ NO public IP                 │  │  │
          │  │  │ outbound → NAT → internet    │  │  │
          │  │  └──────────────────────────────┘  │  │
          │  └────────────────────────────────────┘  │
          └─────────────────────────────────────────┘
```

### Request Flow
```
1. Client sends POST /v1/chat/completions to API Gateway public IP :3111
2. Internet Gateway routes request to API Gateway VM (public subnet)
3. caller-worker (TypeScript) receives request via iii engine
4. iii engine dispatches RPC call over WebSocket :49134 to inference-worker
5. inference-worker (Python) runs gemma-3-270m model in private subnet
6. Inference result returns via RPC to caller-worker
7. JSON response returned to client
```

---

## Infrastructure

| VM | Subnet | Instance | Role | Public IP |
|---|---|---|---|---|
| API Gateway | Public (10.0.1.0/24) | t3.small | iii engine + caller-worker (TypeScript) + HTTP :3111 | Yes |
| Bastion Host | Public (10.0.1.0/24) | t3.micro | SSH jump access to private subnet | Yes |
| Inference Worker | Private (10.0.2.0/24) | t3.medium | inference-worker (Python) + gemma-3-270m | No |

### Security Groups

| VM | Inbound | Outbound |
|---|---|---|
| Bastion Host | SSH :22 (your IP only) | All |
| API Gateway | HTTP :3111 (internet), WebSocket :49134 (VPC), SSH :22 (bastion) | All |
| Inference Worker | WebSocket :49134 (API GW only), SSH :22 (bastion only) | All via NAT |

---

## Prerequisites

- AWS account with IAM credentials (Access Key + Secret Key)
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.0 installed
- [AWS CLI](https://aws.amazon.com/cli/) installed and configured
- An AWS EC2 Key Pair (created in EC2 → Key Pairs → Create)

---

## Deploy from Scratch

### Step 1 — Clone this repo
```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/alchemyst-assignment.git
cd alchemyst-assignment
```

### Step 2 — Configure AWS credentials
```bash
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Default region: us-east-1
# Default output format: json
```

### Step 3 — Set your variables
```bash
cp terraform.tfvars.example terraform.tfvars
```
Edit `terraform.tfvars`:
```hcl
your_ip       = "YOUR_PUBLIC_IP/32"   # run: curl ifconfig.me
key_pair_name = "your-key-pair-name"  # name of your AWS key pair
```

### Step 4 — Deploy
```bash
terraform init
terraform plan
terraform apply
# type "yes" when prompted
```

### Step 5 — Get your outputs
After apply completes, Terraform prints:
```
api_gateway_public_ip        = "x.x.x.x"
bastion_public_ip            = "x.x.x.x"
inference_worker_private_ip  = "10.0.2.x"
inference_api_endpoint       = "http://x.x.x.x:3111/v1/chat/completions"
curl_test_command             = "curl -X POST http://..."
ssh_to_bastion               = "ssh -i ~/.ssh/key.pem ubuntu@x.x.x.x"
ssh_to_inference_via_bastion = "ssh -i ... -J bastion inference-ip"
```

---

## Test the API

### Sample Request
```bash
curl -X POST http://<API_GATEWAY_PUBLIC_IP>:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "What is the capital of France?"}
    ]
  }'
```

### Sample Response
```json
{
  "result": "The capital of France is Paris."
}
```

### Request Schema
| Field | Type | Description |
|---|---|---|
| `messages` | array | List of message objects |
| `messages[].role` | string | Either `"user"` or `"assistant"` |
| `messages[].content` | string | The message text |

---

## SSH Access

```bash
# SSH into bastion host
ssh -i ~/.ssh/alchemyst-key.pem ubuntu@<BASTION_PUBLIC_IP>

# SSH into inference worker via bastion (jump host)
ssh -i ~/.ssh/alchemyst-key.pem \
  -J ubuntu@<BASTION_PUBLIC_IP> \
  ubuntu@<INFERENCE_PRIVATE_IP>
```

---

## Tear Down

```bash
terraform destroy
# type "yes" when prompted
```
This removes all AWS resources — VMs, VPC, subnets, NAT Gateway, security groups.

---

## What I Would Harden Before Production

1. **HTTPS/TLS** — Put an Application Load Balancer with an ACM certificate in front of the API Gateway so all traffic is encrypted in transit. Currently HTTP is used on port 3111.

2. **IAM Roles** — Replace hardcoded AWS credentials with IAM instance roles so EC2 VMs only have the permissions they need, following least-privilege.

3. **Secrets Management** — Store any API keys or tokens in AWS Secrets Manager instead of environment variables or config files on disk.

4. **Auto Scaling** — Put inference workers behind an Auto Scaling Group so the system handles load spikes without manual intervention.

5. **Monitoring & Alerting** — Add CloudWatch alarms for CPU, memory, and API error rates. Set up structured logging from all workers to CloudWatch Logs.

6. **VPC Endpoints** — Add VPC endpoints for AWS services so traffic never leaves the AWS network.

7. **Bastion Hardening** — Replace the bastion host with AWS Systems Manager Session Manager to eliminate the need for any open SSH port entirely.

8. **WAF** — Attach AWS WAF to the API endpoint to block common web attacks and rate-limit abusive clients.

---

## What I Would Do Differently for a 100x Larger Model

1. **GPU Instances** — Switch inference workers from t3.medium to GPU instances (g4dn.xlarge or p3.2xlarge) since a model 100x larger cannot run on CPU within acceptable latency.

2. **Model Sharding** — Split the model across multiple GPU VMs using tensor parallelism so no single machine needs to hold the entire model in memory.

3. **Faster Storage** — Use NVMe instance storage or EFS with high throughput to load model weights quickly at startup instead of downloading from the internet each time.

4. **Inference Optimization** — Apply quantization (INT8/INT4) and use optimized runtimes like vLLM or TensorRT-LLM to reduce GPU memory footprint and increase throughput.

5. **Async Queue** — Replace synchronous RPC with an async job queue (SQS + workers) so the API can accept requests without blocking while inference runs.

6. **Multi-AZ** — Spread inference workers across multiple Availability Zones for fault tolerance, with a load balancer distributing requests.

7. **Spot Instances** — Use EC2 Spot Instances for inference workers to reduce GPU costs by up to 70%, with on-demand fallback for reliability.


## Submission

**Candidate:*GODWILL ORUAN
**Email:** umoramini@gmail.com
**Assignment:** DevOps Internship — Alchemyst AI
**Submitted to:** anuran@getalchemystai.com
**CC:** saumitra@getalchemystai.com, khushi@getalchemystai.com
## Troubleshooting & Known Limitations

### KVM / Nested Virtualization Issue
During deployment testing on AWS Free Tier (t3.micro/t3.small), 
the iii worker runtime failed with:
/dev/kvm does not exist. Ensure KVM is enabled in your kernel.

**Root Cause:** The iii framework depends on nested virtualization 
for worker sandbox execution. AWS Free Tier instances (t3.micro, 
t3.small) do not expose /dev/kvm.

**Solution for Production:** Use AWS instances that support nested 
virtualization such as C8i, M8i, or R8i instance families with 
nested virtualization explicitly enabled.

**What was successfully deployed:**
- VPC with public and private subnets
- NAT Gateway and Internet Gateway
- 3 EC2 instances (API Gateway, Bastion Host, Inference Worker)
- iii engine running on port 3111
- Security groups with proper network hygiene
- Full Terraform IaC (16 resources)
