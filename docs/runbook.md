# Runbook

## First-time setup (in order)

1. **Bootstrap AWS** — run `bootstrap/bootstrap.sh` in CloudShell (see `bootstrap/README.md`).
2. **GitHub variables** — add `AWS_REGION`, `TF_STATE_BUCKET`, `AWS_PLAN_ROLE_ARN`,
   `AWS_APPLY_ROLE_ARN` as repository variables.
3. **Tailscale**
   1. Create the tailnet with the sign-in you will keep (Google, Microsoft, GitHub, Apple,
      passkey…). A tailnet created with GitHub or Apple cannot move to another provider later.
   2. In the access-control policy, add a tag owner:
      `"tagOwners": { "tag:interview-prep": ["autogroup:admin"] }`
   3. Settings -> Keys -> *Generate auth key*: not reusable, not ephemeral, pre-approved,
      tag `tag:interview-prep`, expiry 1–7 days.
   4. Save it as the repository **secret** `TAILSCALE_AUTH_KEY`.
   5. Invite the second learner with an invite link; they can use any sign-in provider.
4. **Merge** the infra pull request once the plan comment looks right.
5. **Apply** — Actions -> *terraform* -> *Run workflow* on `main`, `confirm` = `apply`,
   then approve the waiting deployment when GitHub asks. See *Approving an apply* below.
6. **Verify** (5–15 minutes after apply):
   ```bash
   tailscale status | grep interview-prep
   tailscale ssh ubuntu@interview-prep
   sudo tail -n 50 /var/log/interview-prep-first-boot.log   # ends with "first boot finished"
   df -h /data                                              # the 8 GB data disk
   docker version
   ```

## Publishing images

The app and content repositories publish to two ECR repositories in this account:

| Repository | Holds |
| --- | --- |
| `interview-prep-app` | The application image. |
| `interview-prep-content` | The validated curriculum bundle. |

Each build pushes an immutable `<commit-sha>` tag and moves a `main` tag to it. The VM's update
timer watches the `main` tag's digest, so nothing has to be told that a new build exists. Both
repositories keep their last 10 images and expire the rest.

Two identities are involved, and neither is a long-lived key in a workflow:

- **Pushing** — GitHub Actions on `main` in the app and content repositories assumes
  `interview-prep-ecr-push` through OIDC. It can push to these two repositories and do nothing else.
- **Pulling** — the VM uses the `backup-writer` access key already in
  `/etc/interview-prep/backup.env`, which now also carries read-only ECR permissions. Lightsail
  instances cannot assume a role and `user_data` only runs at first boot, so reusing the key that is
  already there avoids inventing a way to deliver a new secret to a running server. The VM resolves
  it into a registry token with `amazon-ecr-credential-helper`; there is no `docker login` to keep
  fresh and no AWS CLI on the box.

If a push fails at the AWS sign-in step, compare the `sub` claim in the run's log with the two
values in `bootstrap/push-role-trust.json`. The most likely cause is a repository having been
re-created, which changes its numeric id — see `bootstrap/README.md`.

## Approving an apply

`apply` runs only when someone starts it by hand on `main` with `confirm = apply`, and then waits
for a required reviewer to approve it in GitHub. Two things have to agree for that to work:

- the `apply` **environment** in this repository (Settings -> Environments), with a required
  reviewer and `main` as its only deployment branch;
- the apply role's trust policy, which accepts the sign-in subject GitHub puts in the token.

A job that names an environment gets a token ending `:environment:apply` instead of
`:ref:refs/heads/main`, so `bootstrap/apply-role-trust.json` accepts **both** forms. The apply job
names the environment, so it signs in with the second one.

The branch form is still accepted as a fallback while the environment path settles. Once it has
been exercised a few times, dropping it from the trust policy and re-running
`bootstrap/bootstrap.sh` narrows the role to approved runs only.

If an apply ever fails at the AWS sign-in step, compare the `sub` claim in the run's log with the
two values in `apply-role-trust.json`. If it never reaches AWS at all and shows as *waiting*, it is
sitting on the environment's approval, not broken.

## Replace the VM on purpose

The launch script only runs at first boot and Terraform ignores later changes to it. To
rebuild the VM (new OS image, rotated backup key, fresh Tailscale key):

1. Put a fresh Tailscale auth key in the `TAILSCALE_AUTH_KEY` secret.
2. Actions -> *terraform* -> *Run workflow* on `main` with `confirm` = `apply` (approve it when
   GitHub asks) and `replace_vm` ticked.
3. **Set the new VM up to run the application**, which the first-boot script does not do. From a
   Mac on the tailnet, in a checkout of `interview-prep-app`:

   ```bash
   ECR_REGISTRY=<account-id>.dkr.ecr.ap-south-1.amazonaws.com
   tailscale ssh ubuntu@interview-prep "sudo ECR_REGISTRY=$ECR_REGISTRY bash -s" < deploy/vm-setup.sh
   ```

   See `deploy/README.md` in that repository. Until this is run, the new VM is on the tailnet but
   serves nothing.

The data disk is detached from the old VM and re-attached to the new one; the first-boot
script formats it only if it is blank, so the database survives a replacement.

Step 1 is the one that bites: the original auth key was single-use and is spent. Without a fresh
key the new VM never joins the tailnet, and since nothing else can reach it, there is no way in
except the Lightsail browser console. Put the key in the secret before starting the apply, not
after.

Note that a **reboot** needs none of this. `user_data` runs once when an instance is created, not
on every boot, and the first-boot script guards itself with `/etc/interview-prep/first-boot.done`
besides. Everything both scripts do is persistent, and systemd restarts the application by
itself.

## Recovery

| Situation | Action |
| --- | --- |
| VM broken or deleted | Replace the VM (above). Data on the separate disk is kept. |
| Data disk lost or corrupted | Restore PostgreSQL from the S3 backup bucket (WAL-G point-in-time or nightly dump) — procedure added with the app in Phase 1. |
| Whole region problem | Restore from S3 into a new VM in another Lightsail region (manual). |

## Pause and resume

Automated pause/resume workflows arrive in Phase 3. Until then: take a manual instance
snapshot, then remove the instance and its public-ports resource from Terraform and apply.
The data disk and backup bucket stay (about $1/month).
