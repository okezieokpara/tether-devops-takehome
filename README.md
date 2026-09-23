## Pre requisties
- Local github workflows with `nektos/act` - https://github.com/nektos/act
- Terraform >= v1.5
- Multipass v1.16.3+mac
- Ansible core v2.21.3
- Python >= 3.9 with the `venv` module, for `make e2e`. The first run installs pytest and requests into `.venv/` from PyPI, so it needs internet access.

## Commands
 - Run `make setup` for basic setup and pre-flight checks
 - Run `make build  ARCH=x64 VARIANT=cpu` to trigger the githbu work flow build pipeline. `ARCH=x64` and `VARIANT=cpu` are optional and uses the above default. Oth values are `ARCH=arm64`, `VARIANT=gpu`. Note that the build process can take a long time and considerable system resources.
 - Run `make up` to provision the VMs (with multipass), configure them with ansible and deploy the build artifact.
 - Run `make verify` to test and verify and all is working well.
 - Run `make e2e` to run the end-to-end inference tests against every node.
 - Run `make api-key` to get the API key
 - Run `make destroy` and `make cleanup` to destroy the infra and cleanup paths


## Infrastructure
The infrastructure layer is written with `terraform` and provisions a configurable number of VMs(with `multipass`). I have chosen multipass because it has the least friction and runs on most macs and windows (WSL). It also has first-class terraform resources and a stable provider.
When the VMs are created, terraform writes the IP addresses and SSH key paths to the inventory file (`ansible/inventory.ini`.) where ansible will pick it up. This is not an ideal solution but a realistic solution given the local scenario.

Ansible is used to configure the create VMs, there a `setup` playbook for basic setup and a `deploy` playbook to deploy the llama.cpp to the servers.



## Build
Our github workflow builds llama.cpp for `{x64, arm64} × {cpu, gpu}` inside Ubuntu 24.04 (CUDA 12.8 image for gpu) and uploads one tarball per combination (`llama-cpp-<version>-linux-<arch>-<variant>.tar.gz`). GPU tarballs bundle the CUDA runtime,
so GPU hosts only need the NVIDIA driver.

The multiplatform build uses a GitHub Actions matrix. `arch: [x64, arm64]` × `variant: [cpu, gpu]` expands into 4 parallel jobs. Each job gets its own settings from `include`:
- `arch` picks the runner: `ubuntu-24.04` for x64 and `ubuntu-24.04-arm` for arm64. Each arch builds natively on its own hardware, with no cross-compiling or emulation.
- `variant` picks the build container and CMake flags: `ubuntu:24.04` for cpu, and `nvidia/cuda:12.8.1-devel-ubuntu24.04` with `-DGGML_CUDA=ON` for gpu. It also sets the ccache size.

`fail-fast: false` keeps the other jobs running when one fails, and each job names its artifact after its arch and variant. To add a platform, add a value to `arch` or `variant` and a matching `include` entry.

### ccache
Builds are cached with `ccache`, which ggml's CMake picks up automatically for C, C++ and CUDA. The cache key is `ccache-<arch>-<variant>-<llama.cpp commit sha>`, so a rebuild of the same commit is almost entirely cache hits. When the version pin moves to a new commit, the `restore-keys` prefix restores the closest older cache for that arch and variant, and only the files that changed are recompiled. The cache is saved even when the build fails, so a retry picks up where it stopped. Size limits are 500M for cpu and 2G for gpu, since the CUDA kernels are much larger.

### Building locally
Locally with act (`.actrc` sets runner images and the artifact path). After each build, but artifacts are uploaded to Github artifacts.  Build only the
matching arch, since the other one runs under emulation:

    act push --matrix arch:arm64 --matrix variant:cpu
    mkdir -p dist && for z in artifacts/*/llama-cpp-*/*.zip; do unzip -oq "$z" -d dist; done

Or from a GitHub Actions run:

    gh run download [run-id] --pattern "llama-cpp-*" -D dist && mv dist/*/*.tar.gz dist/

## Deploy

Deploy is managed by ansible, The `deploy.yml` playbook rolls out one node at a time: it unpacks into `/opt/llama.cpp/releases/<version>-<variant>`, points `/opt/llama.cpp/current` at it, restarts `llama-server`, then checks it on the node before moving on: `/health` returns 200 (up to 10 minutes, since the first start downloads the model), a one-token `/completion` succeeds, and the running process is the new release's binary. A failing node stops the rollout, so the rest of the fleet keeps serving the old release. The last 3 releases are kept, so rolling back is re-running with `-e llama_cpp_version=<previous>`.

For resilience, `llama-server` runs as a systemd service: it starts on boot, restarts on failure, and runs as the unprivileged `llama` user. Check it with `systemctl status llama-server` and `journalctl -u llama-server`.

Prometheus-compatible metrics are enabled by default with `--metrics` and exposed at `/metrics` on the API port. Prometheus can scrape `http://<node-ip>:8080/metrics` from a network that can reach the nodes.

The llama.cpp release is pinned in `LLAMA_CPP_VERSION`; the build workflow checks out
that tag and Ansible deploys the tarball of the same version.

    terraform -chdir=terraform init
    terraform -chdir=terraform apply -var vm_count=3
    cd ansible
    ansible-playbook setup.yml     # base packages, service user, directories
    ansible-playbook deploy.yml -e 'llama_cpp_model_args="-hf <user>/<repo>-GGUF"'

Terraform writes `ansible/inventory.ini` (one entry per VM, so it follows `vm_count`) and
the fleet SSH key it generates to `terraform/.generated/`.

### Secrets

Ansible Vault is used to encyrpt and manage secrets. And stored in `ansible/group_vars/all/vault.yml`, encrypted with. Today that is the llama-server API key: every endpoint except `/health` and `/models` needs it as `Authorization: Bearer <key>`. 

Ansible reads the vault password from `ANSIBLE_VAULT_PASSWORD`, or else from `ansible/.vault_pass` (git-ignored), via `ansible/vault-pass.sh`.

    ansible-vault view group_vars/all/vault.yml    # from ansible/
    ansible-vault edit group_vars/all/vault.yml

Without the password, `make vault` starts over with a new password and a new API key
(it refuses to overwrite an existing `ansible/.vault_pass`). On the nodes the key is in `/etc/llama-server.env` (root, `0600`), not in the unit file or the
process arguments.

To call the API, get the key with `make api-key` (it needs the vault password too):

    KEY=$(make -s api-key)
    curl http://<node-ip>:8080/completion \
      -H "Authorization: Bearer $KEY" \
      -d '{"prompt": "Hello", "n_predict": 16}'


## Checks && Verification
Verification runs at two points, and both use the same checks (`roles/llama_cpp/tasks/verify.yml`):
- **During deploy,** on each node after its restart, against `127.0.0.1`. A node that fails stops the rollout before the next node is touched.
- **After deploy,** `make verify` (`verify.yml`) checks every node from your machine on `<node-ip>:8080`, so it also tests the network path and the bind address. `make up` runs it automatically, and you can run it on its own at any time.

The checks: `/health` returns 200 (retried while the model downloads and loads), a one-time `/completion` with the API key succeeds, and the same request without the key is refused with 401.

To check manually, open `http://<node-ip>:8080/health` in a browser, or call. You can also verify the chat, get the API key as stated above

### End-to-end inference tests
`make verify` shows a node can produce one token. `make e2e` tests what clients rely on. It is a pytest suite (`tests/e2e/`) that runs from your machine against every node in `ansible/inventory.ini`, using the API key from the vault. It creates `.venv/` the first time it runs. For each node it checks:
- **Correctness:** a factual question ("capital of France") gets the right answer, through the OpenAI-compatible `/v1/chat/completions`.
- **Determinism:** the same greedy request twice gives the same text.
- **API contract:** `max_tokens` is honoured (`finish_reason: length`, exact token count), and SSE streaming ends with `[DONE]` and has the same answer.
- **Tokenizer:** `/tokenize` and `/detokenize` round-trip.
- **Concurrency:** twice as many parallel requests as the server has slots all succeed and are correct.
- **Performance:** generation stays above 5 tokens/s. The CPU fleet does about 40, so a slower node has the wrong build or CPU kernels.
- **Auth:** a missing or wrong key gets 401.

Across the fleet, it checks every node loads the same model file and build, and gives the same tokens for the same prompt, so a load balancer in front of the nodes would not change the answers clients get.

Greedy decoding is only reproducible with `cache_prompt: false`. With prompt caching on, a request that reuses a cached prefix computes slightly different logits, so output varies between requests and between nodes. The reproducibility tests turn caching off. Clients that need reproducible output must do the same.

## Observability and Metrics
Every node exposes Prometheus metrics at `http://<node-ip>:8080/metrics`, on the same port as the API. They are turned on by the `--metrics` flag, which is set in `llama_cpp_extra_args` (`roles/llama_cpp/defaults/main.yml`).

The targets are the addresses in `ansible/inventory.ini`. To see the raw output:

    curl -H "Authorization: Bearer $(make -s api-key)" http://<node-ip>:8080/metrics

The metrics that matter most for running the fleet:

| Metric | What it tells you |
| --- | --- |
| `llamacpp:requests_processing` | Requests being generated right now. When this sits at the slot count (4 by default), the node is full. |
| `llamacpp:requests_deferred` | Requests waiting for a free slot. If this stays above zero, add nodes or slots. |
| `llamacpp:tokens_predicted_total`, `llamacpp:prompt_tokens_total` | Counters of generated and prompt tokens. Use `rate()` on them for throughput. |
| `llamacpp:tokens_predicted_seconds_total`, `llamacpp:prompt_seconds_total` | Counters of time spent generating and processing prompts. Divide the token counters by these to get speed (below). |
| `llamacpp:prompt_tokens_cached_total` | Prompt tokens served from the prompt cache instead of recomputed. |

There is no Prometheus server, dashboard or alerting in this setup yet. The nodes only expose the metrics.

## Code quality
I have setup a `checks.yml` github workflow that check code quality and runs lint on both terraform and ansible on every push. The Check workflow runs on pushes and pull requests that touch `terraform/`, `ansible/` or the workflows: `terraform fmt`/`validate` and
TFLint (`terraform/.tflint.hcl`), a playbook syntax check and ansible-lint at the
`production` profile (`ansible/.ansible-lint`), and actionlint and ShellCheck on the
workflows and scripts. `make check` runs the same workflow locally with act.



`verify.yml` (`make verify`) runs the same `/health` and `/completion` checks against every
node's address from the controller, which also covers the network path and the bind address.
`make up` runs it after `deploy.yml`.

The variant is picked per host from its architecture and whether an NVIDIA driver is
loaded (override with `-e llama_cpp_variant=cpu|gpu`).

## Idempotency
The system is built to be idempotent, the build artificats and build cache is fixed to a specicif version which is written to the file `LLAMA_CPP_VERSION`. The infrastructure is managed by terraform and doesn't change as long as state is unchnaged. The ansible is also built to be idempotent. The terraform logic has tests to avoid duplicate IP assignments, which happened once during my testing

## Further work
Ideally, there are a couple of improvments we could make with this solutioin.
- Implement a load balancer across the VMs with logic to take out any failing node
- Implement better monitoring