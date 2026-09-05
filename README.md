# codex-ssh

A Docker image for running a remote SSH worker with Go, Git, and the Codex CLI.

The image is intended for use from a remote Code App connection. SSH access and
Codex credentials are configured at runtime so secrets are not baked into the
image or published to Docker Hub.

## Contents

- Base image: `golang:1.26.8-bookworm`
- Codex CLI: `0.153.4`, installed with its companion executables and sandbox resources
  from the official Linux package; SHA-256 checked before extraction
- Tools: Go, Git, OpenSSH server/client, curl, CA certificates, and basic shell utilities
- SSH user: `codex`
- Exposed port: `22`
- Persistent volumes:
  - `/home/codex` for Codex config, SSH state, shell history, caches, and user tooling
  - `/workspace` for repositories and active work
  - `/var/lib/sshd` for the private SSH server identity (root-owned)

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
docker volume create codex-host-keys

docker run -d \
  --name codex-ssh \
  -p 2222:22 \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -v codex-home:/home/codex \
  -v codex-workspace:/workspace \
  -v codex-host-keys:/var/lib/sshd \
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

An explicitly set `AUTHORIZED_KEYS_FILE` must be a readable regular file,
even when `AUTHORIZED_KEYS` is also provided. Empty or invalid supplied keys
stop startup. Valid replacements are written atomically; a failed replacement
leaves the previous file intact, but the container does not start.

Password login and root login are disabled.

### SSH server identity

The container generates an Ed25519 host key on first startup and stores it in
`/var/lib/sshd`. Give each deployment its own `codex-host-keys` volume and reuse
that volume when replacing its container. Do not share it between running
containers. The image contains no private host keys. Startup reconstructs the public-key
file from the private key so fingerprint checks report the served identity.

### Volume permissions

The user is fixed as `codex` (UID/GID 1000), with `HOME=/home/codex`. Codex
uses `/home/codex/.codex` in SSH sessions and `docker exec --user codex`.
SSH sets `CODEX_HOME` explicitly; `docker exec --user codex` uses Codex's default
under that user's home. Root uses `/root` and a system-only command search path.
Do not set `HOME` or `CODEX_HOME` globally on the container.

SSH sessions include the user's Go tooling directories in `PATH`. To run tools
installed there with Docker, use their full path and `--user codex`.

New named volumes inherit the image's ownership. Bind-mounted home and workspace
directories must already be writable by UID/GID 1000. Startup does not change
their ownership or traverse repositories and caches to repair permissions.
The `/var/lib/sshd` mount must be root-owned; startup restricts it to mode 0700
and its private host key to mode 0600.

## Codex credentials

Do not put Codex credentials in the image. To initialize API-key authentication
at startup, add this option to `docker run` after setting a nonempty key:

```sh
-e OPENAI_API_KEY="$OPENAI_API_KEY"
```

The entrypoint pipes the key into `codex login --with-api-key` as the `codex`
user. It stores credentials in `/home/codex/.codex/auth.json` and removes the
key from the environment before starting SSH. Supplying a key replaces stored
authentication on each startup. An explicitly empty or whitespace-only key
stops startup; omitting the variable preserves the existing login.
Use Codex's default file credential store with this option. Docker administrators
can still inspect values supplied with `docker run -e`.

Alternatively, mount a dedicated Codex configuration directory already owned
by UID/GID 1000:

```sh
-v /path/to/codex-config:/home/codex/.codex
```

It must contain file-based credentials; credentials held only in your host's
OS keychain are not included in a directory mount. Treat `auth.json` as a secret.

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
workspace. If it is unavailable, authenticate locally and copy the file-based
login cache, or forward the browser callback over SSH. See the
[official authentication instructions](https://learn.chatgpt.com/docs/auth).

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

ssh-keyscan github.com > /tmp/github-host-keys
ssh-keygen -lf /tmp/github-host-keys
```

Compare the fingerprints with
[GitHub's published SSH fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
before trusting the keys. Then install the verified keys:

```sh
cat /tmp/github-host-keys >> ~/.ssh/known_hosts
rm /tmp/github-host-keys
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

Reuse all three named volumes when replacing the container. If upgrading from
an image that only used home and workspace volumes, create the host-key volume
first:

```sh
docker volume create codex-host-keys
```

That first upgrade changes the server fingerprint because older images contained
a shared private host key. Do not copy that key into the new volume. After
starting the replacement, read its new fingerprint through your trusted Docker
connection:

```sh
docker exec codex-ssh ssh-keygen -lf /var/lib/sshd/ssh_host_ed25519_key.pub
```

Compare this with the fingerprint shown by SSH before updating the matching
`known_hosts` entry. Subsequent replacements keep the identity when the same
host-key volume is mounted. Rolling back to an older image can change the
fingerprint again because it does not use this volume.

Pull and replace:

```sh
docker pull pmenglund/codex-ssh:latest
docker rm -f codex-ssh

docker run -d \
  --name codex-ssh \
  -p 2222:22 \
  -v codex-home:/home/codex \
  -v codex-workspace:/workspace \
  -v codex-host-keys:/var/lib/sshd \
  pmenglund/codex-ssh:latest
```

If authorized keys and Codex credentials are already present in `codex-home`,
they do not need to be passed again. Reapply any additional runtime options or
bind mounts from your deployment.

Credentials previously initialized through `docker exec` with the old
`CODEX_HOME=/home/codex` may be stored directly in `/home/codex/auth.json`.
Inspect that file separately and, if it contains the login you want, migrate it
to `/home/codex/.codex/auth.json` as `codex` with mode 0600. Do not overwrite an
existing login without checking which account it belongs to.

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

## Dependency updates

Dependabot opens weekly pull requests for the Go base image and GitHub Actions.
Each pull request runs the two-architecture smoke tests before publishing is
allowed after merge.

Codex updates require changing `CODEX_VERSION`, `CODEX_SHA256_AMD64`, and
`CODEX_SHA256_ARM64` together in `Dockerfile`, plus the version above. Use the
`digest` values for `codex-package-x86_64-unknown-linux-musl.tar.gz` and
`codex-package-aarch64-unknown-linux-musl.tar.gz` from the corresponding
[official GitHub release API](https://api.github.com/repos/openai/codex/releases/latest).
Keep the SHA-256 hex value without the `sha256:` prefix. A version override
without matching digests fails the build. Build and test both architectures
before publishing.

The smoke test supports Bash 3.2 and newer. It checks SSH access restrictions,
server identity persistence and uniqueness, invalid key configuration, API-key
login with a dummy credential, and ownership preservation. It makes no model
requests and does not need a real API key.
