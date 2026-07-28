# Terraform CI/CD Pipeline with GitHub Actions

An automated pipeline for deploying AWS infrastructure. Open a pull request and it shows you exactly what would change. Merge it and the change goes live. No AWS keys stored anywhere.

## What happens when

| When | What runs |
|---|---|
| You open a pull request | Format check, validation, linting, security scan, and a `terraform plan` posted as a comment |
| You merge to `main` | `terraform apply`, so the change goes live in AWS |

You can't skip these. Branch protection blocks pushing straight to `main`, and a pull request won't merge until the checks pass.

## How it fits together

```
Open a pull request
   │
   ├─ terraform fmt / validate    Is the code formatted and syntactically valid?
   ├─ tflint                      Does it follow Terraform best practices?
   ├─ checkov                     Any security misconfigurations? (blocks the merge)
   └─ terraform plan              What would change? Posted as a PR comment.
   │
Merge to main
   │
   └─ terraform apply             The change is made in AWS

Throughout: GitHub proves its identity to AWS using OIDC, so no credentials are stored
```

## Why OIDC instead of access keys

The usual approach is to create an AWS access key and store it in GitHub Secrets. That key is long-lived. If it leaks, whoever has it keeps access until you notice and rotate it.

This pipeline uses OIDC. Every workflow run gets a fresh token signed by GitHub, valid for a few minutes. AWS checks the token against a trust policy that's pinned to this specific repository, then hands back temporary credentials that expire on their own. There's no stored key to leak in the first place.

## What the pipeline is allowed to do

The IAM role it assumes is deliberately narrow:

- Terraform state bucket: read and write, that bucket only
- State lock table: read, write and delete items, that table only
- Demo resources: full S3 permissions, but only on buckets named `morgan-cicd-demo-*`

It can't touch anything else in the account. If the pipeline were ever compromised, that's the limit of the damage.

## Security scanning

Checkov scans every pull request and blocks the merge if it finds a problem.

Four of its checks are switched off. The reason for each is written into `main.tf` next to the code:

| Check | Why it's skipped |
|---|---|
| `CKV_AWS_18` (access logging) | Would need a second bucket just to hold the logs |
| `CKV_AWS_144` (cross-region replication) | Costs money and does nothing useful for a demo |
| `CKV2_AWS_61` (lifecycle rules) | The bucket doesn't store anything |
| `CKV2_AWS_62` (event notifications) | Needs an SNS or Lambda target that doesn't exist here |

Switching off checks without recording why is how a scanner turns into background noise that everyone ignores. Each of these is a decision someone can read and argue with.

## Built with

- AWS: S3, DynamoDB, IAM, OIDC identity provider
- Terraform v1.x, AWS provider v5, S3 remote backend
- GitHub Actions, with OIDC authentication and PR comments via `github-script`
- tflint for linting
- checkov for security scanning

## Files

```
.
├── .github/workflows/terraform.yml   # the pipeline
├── main.tf                           # the S3 bucket and its security settings
├── versions.tf                       # provider versions and where state is stored
└── README.md
```

## Running this yourself

1. Create an S3 bucket for Terraform state and a DynamoDB table for locking.
2. In IAM, add an OIDC identity provider for `token.actions.githubusercontent.com` with audience `sts.amazonaws.com`.
3. Create an IAM role that trusts that provider, restricted to your repository, with permissions covering your state bucket, lock table and whatever you're deploying.
4. Add the role's ARN as a repository variable called `AWS_ROLE_ARN`.
5. Point the backend block in `versions.tf` at your bucket and table.
6. Turn on branch protection for `main`. Require a pull request, and require the `checks` job to pass.

## Problems I hit and how I solved them

### The pipeline couldn't authenticate and the trust policy looked correct

Every run failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. I checked the trust policy, the OIDC provider, the audience, the role ARN and the username casing. All fine.

Rather than keep guessing, I added a temporary step that decoded the token GitHub was actually sending and printed it into the workflow log. The subject claim came back as:

```
repo:mifidon96@86232639/terraform-cicd-demo@1307772990:pull_request
```

The trust policy was expecting `repo:owner/repo:event`. GitHub changed this format in July 2026 for newly created repositories, so the subject now carries numeric account and repository IDs alongside the names. Updating the trust policy to match fixed it straight away.

The new format is also harder to abuse. Usernames and repository names can be given up and claimed by someone else. The numeric IDs can't.

### Every apply hit a different permissions error

The first apply failed on `s3:CreateBucket`, so I added it. The next failed on `s3:GetBucketPolicy`. Added that too. The one after failed on `s3:GetAccelerateConfiguration`.

The AWS provider reads back roughly fifteen separate bucket settings on every run, regardless of whether the Terraform code configures them. Adding permissions one error at a time was never going to converge.

I changed approach and granted all S3 actions, but restricted by resource to bucket names matching `morgan-cicd-demo-*`. The role can do whatever it likes to the buckets this pipeline creates and nothing at all to any other bucket in the account.

The useful measure for least privilege turned out to be how much damage a compromised role could do, rather than how short the list of allowed actions is.

### A security scanner that can't block anything doesn't achieve much

I started checkov in `soft_fail` mode, which reports problems but lets the build pass anyway. That was the right call initially. It surfaced all seven findings without blocking me while I worked out what to do about them.

Left like that, though, it's a warning nobody reads. Once I'd fixed the three real issues and documented why the other four didn't apply, I turned `soft_fail` off. A new misconfiguration now stops the merge.
