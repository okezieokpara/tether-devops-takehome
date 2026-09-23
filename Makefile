LLAMA_CPP_VERSION := $(shell cat LLAMA_CPP_VERSION)
# get the current locked version


# Build for the host arch by default; the other one runs under emulation.
# Override either with e.g. make build ARCH=x64 VARIANT=gpu.
ARCH ?= $(if $(filter arm64 aarch64,$(shell uname -m)),arm64,x64)
VARIANT ?= cpu
# Small enough for the default 2G VMs. Override by exporting LLAMA_CPP_MODEL_ARGS.
export LLAMA_CPP_MODEL_ARGS ?= -hf ggml-org/gemma-3-1b-it-GGUF

.DEFAULT_GOAL := setup
.PHONY: build fetch vault api-key plan up setup deploy verify e2e destroy check clean

build: ## Build the ARCH/VARIANT tarball (default: this machine, cpu) with act, into dist/
	act push -W .github/workflows/build.yml --matrix arch:$(ARCH) --matrix variant:$(VARIANT)
	mkdir -p dist
	for z in artifacts/*/llama-cpp-*/*.zip; do python3 -m zipfile -e "$$z" dist; done

fetch: ## Download the latest successful CI build on main into dist/ instead
	mkdir -p dist
	gh run download $$(gh run list --workflow build.yml --branch main --status success \
		--limit 1 --json databaseId -q '.[0].databaseId') --pattern "llama-cpp-$(LLAMA_CPP_VERSION)-*" -D dist
	mv dist/*/*.tar.gz dist/ && find dist -mindepth 1 -type d -empty -delete

vault: ## Create ansible/.vault_pass and a vault holding a fresh llama-server API key
	@test ! -e ansible/.vault_pass || { echo "ansible/.vault_pass exists; remove it to start a new vault" >&2; exit 1; }
	umask 077 && openssl rand -base64 32 > ansible/.vault_pass
	printf 'vault_llama_cpp_api_key: %s\n' "$$(openssl rand -hex 32)" \
		| (cd ansible && ansible-vault encrypt --output group_vars/all/vault.yml -)

api-key: ## Print the llama-server API key from the vault
	@cd ansible && ansible-vault view group_vars/all/vault.yml | sed -n 's/^vault_llama_cpp_api_key: *//p'

setup: ## Check tools, dist/ tarball, vault and environment before a deploy
	@fail=0; \
	for tool in terraform ansible-playbook ansible-vault ansible-galaxy multipass; do \
		command -v $$tool >/dev/null || { echo "setup: $$tool not found on PATH" >&2; fail=1; }; \
	done; \
	ansible-galaxy collection list community.general 2>/dev/null | grep -q community.general \
		|| { echo "setup: Ansible collection community.general missing (install the full ansible package)" >&2; fail=1; }; \
	multipass list >/dev/null 2>&1 || { echo "setup: multipass daemon not reachable" >&2; fail=1; }; \
	tarball=dist/llama-cpp-$(LLAMA_CPP_VERSION)-linux-$(ARCH)-$(VARIANT).tar.gz; \
	test -f $$tarball || { echo "setup: $$tarball missing; run make build or make fetch" >&2; fail=1; }; \
	test -f ansible/group_vars/all/vault.yml || { echo "setup: ansible/group_vars/all/vault.yml missing; run make vault" >&2; fail=1; }; \
	(cd ansible && ansible-vault view group_vars/all/vault.yml >/dev/null 2>&1) \
		|| { echo "setup: cannot decrypt the vault; set ANSIBLE_VAULT_PASSWORD or run make vault" >&2; fail=1; }; \
	test -n "$$LLAMA_CPP_MODEL_ARGS" || { echo "setup: LLAMA_CPP_MODEL_ARGS is empty" >&2; fail=1; }; \
	test $$fail -eq 0 && echo "setup: ok ($(LLAMA_CPP_VERSION), $(ARCH)-$(VARIANT), $$LLAMA_CPP_MODEL_ARGS)"; \
	exit $$fail

plan: ## Show what Terraform would change in the fleet, saved to terraform/tfplan
	terraform -chdir=terraform init -input=false
	terraform -chdir=terraform plan -input=false -out=tfplan

up: setup plan ## Check, plan, provision from that plan, then deploy and verify
	terraform -chdir=terraform apply -input=false tfplan
	rm -f terraform/tfplan
	multipass start $$(terraform -chdir=terraform output -raw node_names)
	$(MAKE) deploy verify

deploy: ## Prepare the nodes and roll out dist/ to them
	cd ansible && ansible-playbook setup.yml deploy.yml

verify: ## Check every node serves completions, from this machine
	cd ansible && ansible-playbook verify.yml

e2e: .venv ## Run the end-to-end inference tests against every node
	LLAMA_API_KEY="$$($(MAKE) -s api-key)" .venv/bin/pytest tests/e2e

.venv: tests/e2e/requirements.txt
	python3 -m venv .venv
	.venv/bin/pip install -q -r tests/e2e/requirements.txt
	touch .venv

destroy: ## Tear down the fleet
	terraform -chdir=terraform destroy -auto-approve -input=false
	rm -f terraform/.generated/known_hosts

check: ## Validate and lint Terraform, the playbooks and the workflows, with act
	# OpenSSL in cryptography's arm64 wheel dies with SIGILL in Docker on Apple Silicon
	# unless its CPU feature detection is off.
	act push -W .github/workflows/check.yml --env OPENSSL_armcap=0

clean: ## Remove build artifacts and any saved plan
	rm -rf artifacts dist terraform/tfplan .venv
