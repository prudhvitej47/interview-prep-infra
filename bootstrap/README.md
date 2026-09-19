# Bootstrap (run once)

`bootstrap.sh` creates the four things Terraform needs before it can run. Everything else
is Terraform.

| Resource | Name | Notes |
| --- | --- | --- |
| S3 bucket | `interview-prep-tfstate-<account-id>` | Terraform state. Private, versioned, encrypted, TLS-only. Locking uses an S3 lock file (no DynamoDB). |
| OIDC identity provider | `token.actions.githubusercontent.com` | Lets GitHub Actions exchange its signed token for short-lived AWS credentials. Reused if it already exists. |
| IAM role | `interview-prep-terraform-plan` | Read-only. Trusted by any branch or PR of `prudhvitej47/interview-prep-infra`. Policy: `plan-role-permissions.json`. |
| IAM role | `interview-prep-terraform-apply` | Trusted only by the `main` branch of that repo. Policy: `apply-role-permissions.json`. |

The script is idempotent (safe to re-run; it updates the policies), creates no access keys,
and prints no secrets. `__PLACEHOLDERS__` in the JSON files are filled in at run time.

## Run it

1. Sign in to the AWS console as an administrator and switch the region to
   **Asia Pacific (Mumbai) ap-south-1**.
2. Open **CloudShell** (terminal icon in the top bar).
3. Get the script. Either upload this folder with *Actions -> Upload file*, or clone the repo:
   ```bash
   git clone https://github.com/prudhvitej47/interview-prep-infra.git
   ```
   (Private repo: when git asks, use your GitHub username and a token as the password.)
4. Run:
   ```bash
   cd interview-prep-infra
   bash bootstrap/bootstrap.sh
   ```
   Review the summary it prints and answer `y`.
5. Check the **Lightsail plans** table at the end: the 2 GB plan at `12.0` USD should be
   `small_3_0`. If the id differs, tell Claude so `terraform/variables.tf` can be updated.
6. Copy the printed values into GitHub (repo -> Settings -> Secrets and variables -> Actions):
   - Variables: `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`
   - Secret: `TAILSCALE_AUTH_KEY` (see `docs/runbook.md`)

## Undo

Delete the two roles (`aws iam delete-role-policy` then `aws iam delete-role`), the OIDC
provider (only if nothing else uses it), and the state bucket (after `terraform destroy`).
