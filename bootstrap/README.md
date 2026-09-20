# Bootstrap (run once)

`bootstrap.sh` creates the four things Terraform needs before it can run. Everything else
is Terraform.

| Resource | Name | Notes |
| --- | --- | --- |
| S3 bucket | `interview-prep-tfstate-<account-id>` | Terraform state. Private, versioned, encrypted, TLS-only. Locking uses an S3 lock file (no DynamoDB). |
| OIDC identity provider | `token.actions.githubusercontent.com` | Lets GitHub Actions exchange its signed token for short-lived AWS credentials. Reused if it already exists. |
| IAM role | `interview-prep-terraform-plan` | Read-only. Trusted by any branch or PR of `prudhvitej47/interview-prep-infra`. Policy: `plan-role-permissions.json`. |
| IAM role | `interview-prep-terraform-apply` | Trusted only by the `main` branch of that repo, and by jobs running in its `apply` environment. Policy: `apply-role-permissions.json`. |
| IAM role | `interview-prep-ecr-push` | Trusted only by the `main` branch of `interview-prep-app` and `interview-prep-content`. Pushes container images to the two ECR repositories and can do nothing else. Policy: `push-role-permissions.json`. |

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
4. Run:
   ```bash
   cd interview-prep-infra
   bash bootstrap/bootstrap.sh
   ```
   Review the summary it prints and answer `y`.
5. Check the **Lightsail plans** table at the end: the 2 GB plan at `12.0` USD should be
   `small_3_1` (the default in `terraform/variables.tf`). If the id differs, tell Claude.
6. Copy the printed values into GitHub (repo -> Settings -> Secrets and variables -> Actions):
   - Variables: `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`
   - Secret: `TAILSCALE_AUTH_KEY` (see `docs/runbook.md`)

## Re-running

The script is safe to run again: it keeps the bucket and provider and rewrites both roles'
trust and permission policies. Re-run it after any change to the files in this folder.

## Why the roles trust numeric ids

GitHub tokens from repos created after 15 July 2026 identify the repo as
`repo:<owner>@<owner-id>/<repo>@<repo-id>`, not `repo:<owner>/<repo>`. The script looks both ids
up and writes that form into the trust policies. A trust policy with the old form fails with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`.

## Undo

Delete the two roles (`aws iam delete-role-policy` then `aws iam delete-role`), the OIDC
provider (only if nothing else uses it), and the state bucket (after `terraform destroy`).

## Repository ids

The roles trust numeric ids rather than names, so a renamed or re-created repository cannot inherit
them. `bootstrap.sh` reads each id from GitHub's public API.

`interview-prep-content` is private, so it cannot be read without a token. Its id is recorded in the
script as `CONTENT_REPO_ID_DEFAULT` — an immutable, non-secret number — and the script says so when
it falls back to it. Override any of them if needed:

```bash
GITHUB_OWNER_ID=... GITHUB_REPO_ID=... APP_REPO_ID=... CONTENT_REPO_ID=... bash bootstrap/bootstrap.sh
```

If the content repository is ever deleted and re-created, update that default. Until it is, the push
role will refuse that repository's workflow with a `sts:AssumeRoleWithWebIdentity` error — which is
the protection working, not a bug.

`bootstrap/checks.sh` covers both risks without needing AWS: that the id lookup resolves correctly
and fails loudly rather than quietly, and that every `__PLACEHOLDER__` in a policy template is one
`render()` actually substitutes. CI runs it on every pull request.
