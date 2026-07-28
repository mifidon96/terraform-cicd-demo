# Terraform CI/CD Pipeline with GitHub Actions

A production-pattern CI/CD pipeline for Terraform: plan on pull request, apply on merge, with linting and security scanning gating every change — and no long-lived AWS credentials anywhere.

## What it does

| Trigger | What runs |
|---|---|
| Pull request to `main` | `fmt` → `validate` → `tflint` → `checkov` → `plan` (posted as a PR comment) |
| Merge to `main` | `terraform apply` |

Branch protection means changes cannot reach `main` any other way — no direct pushes, no merging with failing checks.

## Architecture

```
Pull request opened
   │
   ├─ terraform fmt / validate        (syntax + formatting)
   ├─ tflint                          (Terraform best practices)
   ├─ checkov                         (security misconfiguration scan — blocks merge on failure)
   └─ terraform plan                  → posted as PR comment for review
   │
Merge to main
   │
   └─ terraform apply                 → live AWS infrastructure

Authentication throughout: GitHub OIDC → AWS IAM role (no stored credentials)
```

## Authentication: OIDC, not access keys

The pipeline authenticates to AWS using GitHub's OIDC provider rather than storing an access key and secret in GitHub Secrets. Each workflow run receives a short-lived token, signed by GitHub, that AWS validates against a trust policy pinned to this specific repository.

No long-lived credentials exist to leak or rotate.

## Least privilege

The IAM role is scoped to only what the pipeline owns:

- **Terraform state bucket** — read/write on the state bucket only
- **State lock table** — `GetItem`/`PutItem`/`DeleteItem` on the DynamoDB lock table only
- **Demo resources** — full S3 actions, but scoped by resource ARN to `morgan-cicd-demo-*`

The role has no access to anything else in the account.

## Security scanning

Checkov runs on every PR with `soft_fail: false` — findings block the merge.

Four checks are explicitly skipped, each with a documented reason inline in `main.tf`:

| Check | Reason for skip |
|---|---|
| `CKV_AWS_18` (access logging) | Requires a second bucket; out of scope for a demo |
| `CKV_AWS_144` (cross-region replication) | Unnecessary and costly for a sandbox |
| `CKV2_AWS_61` (lifecycle config) | Bucket holds no objects |
| `CKV2_AWS_62` (event notifications) | Requires an SNS/SQS/Lambda target not present |

Suppressing findings without a stated reason is how scanners become noise. Each skip here is a recorded decision, visible in code review.

## Tech used

- **AWS** — S3 (state + demo bucket), DynamoDB (state locking), IAM, OIDC identity provider
- **Terraform** — v1.x, AWS provider v5, S3 remote backend
- **GitHub Actions** — OIDC auth, PR/push-triggered jobs, PR commenting via `github-script`
- **tflint** — Terraform linting
- **checkov** — security and misconfiguration scanning

## Repository layout

```
.
├── .github/workflows/terraform.yml   # the pipeline
├── main.tf                           # demo resources (S3 bucket + hardening)
├── versions.tf                       # provider versions + S3 backend config
└── README.md
```

## Setting this up yourself

1. Create an S3 bucket for Terraform state and a DynamoDB table for state locking
2. Create an IAM OIDC identity provider for `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`
3. Create an IAM role with a trust policy pinned to your repository, and a permissions policy scoped to your state bucket, lock table, and target resources
4. Add the role ARN as a repository variable named `AWS_ROLE_ARN`
5. Update the backend block in `versions.tf` with your bucket and table names
6. Enable branch protection on `main`: require a PR, and require the `checks` status check to pass

## What I learned

**GitHub's immutable OIDC subject claims.** The pipeline failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity` despite a trust policy that looked correct. Rather than guessing, I added a temporary step to decode the actual OIDC token in the workflow log — which revealed GitHub now issues a subject claim in the format `repo:owner@ownerID/repo@repoID:event` for repositories created after 15 July 2026, embedding numeric IDs instead of names. Updating the trust policy to pin those IDs fixed it, and is more secure than name-based matching: a recycled username or repository name can't be used to impersonate the original.

**Least privilege is iterative, not up-front.** The first `apply` failed on `s3:CreateBucket`. Adding that surfaced a failure on `s3:GetBucketPolicy`, then `s3:GetAccelerateConfiguration` — the AWS provider reads back a large number of bucket sub-configurations on every apply, whether or not the Terraform code sets them. Rather than enumerating them indefinitely, I scoped the policy by *resource* instead of by action: full S3 permissions, but only on ARNs matching `morgan-cicd-demo-*`. The blast radius is what matters, not the action count.

**Security scanning has to be able to say no.** Checkov initially ran with `soft_fail: true`, which reports findings without failing the build. That was useful for establishing a baseline, but a scanner that can't block a merge isn't a control. Once the real findings were fixed and the out-of-scope ones documented, I switched it to fail the build.