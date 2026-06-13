# codex-ssh

A Docker image for running a remote SSH worker with Go, Git, and the Codex CLI.

The image is intended for use from a remote Code App connection. SSH access and
Codex credentials are configured at runtime so secrets are not baked into the
image or published to Docker Hub.

## Contents

- Base image: `golang:1.26.4-bookworm`
- Codex CLI: `0.139.0`, downloaded directly from GitHub release assets
- Tools: Go, Git, OpenSSH server/client, curl, CA certificates, and basic shell utilities
- SSH user: `codex`
- Exposed port: `22`
- Persistent volumes:
  - `/home/codex` for Codex config, SSH state, shell history, caches, and user tooling
  - `/workspace` for repositories and active work

## Build locally

```sh
docker build -t codex-ssh:test .
```

Run the smoke test:

```sh
scripts/smoke-test.sh codex-ssh:test
```

To force a specific platform, set `PLATFORM`:

```sh
PLATFORM=linux/amd64 scripts/smoke-test.sh codex-ssh:test
PLATFORM=linux/arm64 scripts/smoke-test.sh codex-ssh:test
```

## Run locally

Create persistent volumes and start the container:

```sh
docker volume create codex-home
docker volume create codex-workspace

docker run -d \
  --name codex-ssh \
  -p 2222:22 \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -v codex-home:/home/codex \
  -v codex-workspace:/workspace \
  pmenglund/codex-ssh:latest
```

Connect over SSH:

```sh
ssh -p 2222 codex@localhost
```

Verify the tools:

```sh
ssh -p 2222 codex@localhost 'go version && git --version && codex --version'
```

## SSH keys

The container requires SSH public keys at runtime. Use one of these options:

```sh
-e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"
```

```sh
-v "$PWD/authorized_keys:/run/secrets/authorized_keys:ro"
```

```sh
-e AUTHORIZED_KEYS_FILE=/some/mounted/authorized_keys
```

If `/home/codex` is a persistent volume and already contains
`/home/codex/.ssh/authorized_keys`, the entrypoint keeps using that file unless
new keys are provided through `AUTHORIZED_KEYS`, `AUTHORIZED_KEYS_FILE`, or
`/run/secrets/authorized_keys`.

Password login and root login are disabled.

## Codex credentials

Do not put Codex credentials in the image. Use one of these runtime options:

```sh
-e OPENAI_API_KEY="$OPENAI_API_KEY"
```

```sh
-v "$HOME/.codex:/home/codex/.codex"
```

You can also SSH into the container and run `codex` to complete an interactive
login. Keeping `/home/codex` on a named volume preserves Codex configuration
across container updates.

### Device code login

For remote or headless containers, use Codex device code authentication instead
of the browser callback flow:

```sh
ssh -p 2222 codex@localhost
codex login --device-auth
```

Codex prints a browser URL and a one-time code. Open the URL on a machine with a
browser, sign in, and enter the code. The login cache is stored under the
persistent `/home/codex` volume, so it survives container updates.

Device code authentication must be enabled for your ChatGPT account or
workspace. If the server does not allow device code login, Codex falls back to
the standard browser-based login flow.

## Git credentials

Use a dedicated SSH key for Git access from the remote container. Do not mount
your personal `~/.ssh` directory wholesale into the container.

Create a key inside the container:

```sh
ssh -p 2222 codex@localhost

mkdir -p ~/.ssh
chmod 700 ~/.ssh

ssh-keygen -t ed25519 -C "codex-ssh@remote" -f ~/.ssh/id_ed25519_github

cat ~/.ssh/id_ed25519_github.pub
```

Add the printed public key to GitHub:

- For broad account access: GitHub → Settings → SSH and GPG keys → New SSH key
- For a single repository: repository → Settings → Deploy keys → Add deploy key

Only enable write access for a deploy key if this container needs to push.

Configure SSH in the container:

```sh
cat > ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github
  IdentitiesOnly yes
EOF

ssh-keyscan github.com >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519_github ~/.ssh/known_hosts
```

Test GitHub SSH access:

```sh
ssh -T git@github.com
git clone git@github.com:pmenglund/codex-ssh.git /workspace/codex-ssh
```

The key and SSH config live under `/home/codex`, so they persist across image
updates when `/home/codex` is mounted as a volume.

## Upgrade flow

Pull a newer image and replace the container while reusing the same volumes:

```sh
docker pull pmenglund/codex-ssh:latest
docker rm -f codex-ssh

docker run -d \
  --name codex-ssh \
  -p 2222:22 \
  -v codex-home:/home/codex \
  -v codex-workspace:/workspace \
  pmenglund/codex-ssh:latest
```

If the authorized keys are already present in `codex-home`, they do not need to
be passed again.

## Docker Hub publishing

The GitHub Actions workflow builds and tests the image for `linux/amd64` and
`linux/arm64`. On pushes to `main` and version tags, it publishes
`pmenglund/codex-ssh` to Docker Hub.

Configure these repository secrets in GitHub:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Published tags include:

- `latest` for `main`
- branch tags
- `sha-<commit>`
- semantic version tags for Git tags such as `v1.2.3`

## Code App connection

Run the container on the remote host and add an SSH connection using:

- Host: the remote Docker host
- Port: the host port mapped to container port `22`
- User: `codex`
- Authentication: the private key matching the public key passed to the container

Use `/workspace` as the default working directory for repositories and remote
operations.
