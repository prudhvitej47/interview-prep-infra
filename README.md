# interview-prep-infra

Terraform for the interview-prep app: one Lightsail VM in Mumbai (ap-south-1), a separate
disk for PostgreSQL data, an S3 bucket for backups, and a narrowly scoped IAM user the VM
uses to write those backups. About $15–16/month.

Terraform runs only in GitHub Actions, authenticating to AWS with short-lived OIDC
credentials. No AWS keys are stored in GitHub, on a laptop, or with Claude.

## Layout

| Path | What it is |
| --- | --- |
| `bootstrap/` | One-time CloudShell script: Terraform state bucket, GitHub OIDC provider, plan and apply roles. See [bootstrap/README.md](bootstrap/README.md). |
| `terraform/` | Everything else: Lightsail instance (+ daily auto-snapshots), data disk, public ports (none open to the internet), backup bucket, backup IAM user. |
| `terraform/templates/first-boot.sh.tftpl` | Runs once when the VM is created: Docker, Tailscale, swap, data-disk mount, backup credentials. |
| `.github/workflows/terraform.yml` | Checks on every PR; read-only plan posted to the PR; manual apply on `main`. |
| `docs/runbook.md` | First-time setup order, day-2 operations, recovery. |

## How changes flow

```
branch -> pull request -> checks + read-only plan comment -> review -> merge to main
       -> Actions tab -> "terraform" -> Run workflow on main with confirm = apply
```

- **Plan role** (`interview-prep-terraform-plan`): read-only, any branch or PR of this repo.
  It cannot read backup objects or instance access details.
- **Apply role** (`interview-prep-terraform-apply`): write access limited to Lightsail in
  ap-south-1, the two `interview-prep-*` buckets, and IAM users under `/interview-prep/`.
  Only a workflow running on `main` can assume it, and apply only runs when you trigger it.

## Security notes

- Claude pushes only to branches and opens pull requests; merging and applying are yours.
- The VM has no public TCP ports except SSH from the Lightsail browser console
  (`lightsail-connect`). Everything else goes through Tailscale.
- Docker containers are blocked from the instance metadata endpoint, which exposes the
  launch script.
- The data disk and backup bucket have `prevent_destroy`; Terraform refuses to delete them.
