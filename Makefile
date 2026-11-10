SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROFILE ?= demo

ENV_COMMON := --env-file $(ROOT)/versions.lock --env-file $(ROOT)/profiles/$(PROFILE).env
COMPOSE_A  := docker compose -f $(ROOT)/node-a/docker-compose.yml $(ENV_COMMON) --env-file $(ROOT)/node-a/.env
COMPOSE_B  := docker compose -f $(ROOT)/node-b/docker-compose.yml $(ENV_COMMON) --env-file $(ROOT)/node-b/.env

.PHONY: help init-env preflight-a preflight-b op-deployer keys secrets-a secrets-b bundle-b install-bundle-b \
        chain-id-check intent funding-table deploy-l1 export verify-onchain lock \
        up-a down-a restart-a logs-a up-b down-b restart-b logs-b status-a status-b peers-a peers-b \
        compare rebuild-b deposit set-init-bond lint

help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

init-env: ## Create .env files from the examples (no overwrite)
	@for f in .env node-a/.env node-b/.env; do \
	  if [ ! -f $(ROOT)/$$f ]; then cp $(ROOT)/$$f.example $(ROOT)/$$f && echo "created $$f"; else echo "exists  $$f"; fi; done

preflight-a: ## Host A checks: tools, images for this CPU, L1 endpoints, flags
	@bash $(ROOT)/scripts/preflight.sh a
preflight-b: ## Host B checks
	@bash $(ROOT)/scripts/preflight.sh b

op-deployer: ## Download the op-deployer binary pinned in versions.lock
	@bash $(ROOT)/scripts/get-op-deployer.sh

keys: ## Generate role keys and node secrets into keys/ (never committed)
	@bash $(ROOT)/scripts/gen-keys.sh
secrets-a: ## Assemble node-a/secrets from keys/
	@bash $(ROOT)/scripts/secrets.sh a
secrets-b: ## Assemble node-b/secrets from keys/ (when keys/ is on host B)
	@bash $(ROOT)/scripts/secrets.sh b
bundle-b: ## Pack host B secrets into keys/node-b-bundle.tar for a one-time move
	@bash $(ROOT)/scripts/secrets.sh bundle-b
install-bundle-b: ## On host B: unpack keys/node-b-bundle.tar into node-b/secrets
	@bash $(ROOT)/scripts/secrets.sh install-b $(ROOT)/keys/node-b-bundle.tar

chain-id-check: ## Registry check for CHAIN_ID plus the manual check list
	@bash $(ROOT)/scripts/chain-id-check.sh

intent: ## op-deployer init + Finchain overrides -> chain/deployer/intent.toml
	@bash $(ROOT)/scripts/render-intent.sh

funding-table: ## Itemised Sepolia ETH budget for PROFILE
	@PROFILE=$(PROFILE) bash $(ROOT)/scripts/funding-table.sh $(GAS_GWEI)

deploy-l1: ## op-deployer apply on Sepolia (spends ETH, asks for confirmation)
	@bash $(ROOT)/scripts/deploy-l1.sh

export: ## Export genesis.json, rollup.json, L1 addresses, chain record
	@bash $(ROOT)/scripts/export-artifacts.sh

verify-onchain: ## Snapshot the live L1 configuration at a fixed block (BLOCK=... optional)
	@bash $(ROOT)/scripts/verify-onchain.sh $(BLOCK)

lock: ## Freeze versions.lock to image digests (after preflight on both hosts)
	@bash $(ROOT)/scripts/lock-images.sh

up-a: ## Start host A stack (PROFILE=demo|lowcost)
	@$(COMPOSE_A) up -d
down-a: ## Stop host A stack (data kept)
	@$(COMPOSE_A) down
restart-a: ## Recreate host A containers with current env (e.g. after editing P2P_STATIC_PEERS)
	@$(COMPOSE_A) up -d --force-recreate
logs-a: ## Follow host A logs (SVC=op-node optional)
	@$(COMPOSE_A) logs -f --tail=200 $(SVC)

up-b: ## Start host B stack
	@$(COMPOSE_B) up -d
down-b: ## Stop host B stack (data kept)
	@$(COMPOSE_B) down
restart-b: ## Recreate host B containers with current env
	@$(COMPOSE_B) up -d --force-recreate
logs-b: ## Follow host B logs (SVC=op-challenger optional)
	@$(COMPOSE_B) logs -f --tail=200 $(SVC)

status-a: ## Heads, peers, balances on host A
	@bash $(ROOT)/scripts/status.sh a $(PROFILE)
status-b: ## Heads, peers, balances on host B
	@bash $(ROOT)/scripts/status.sh b $(PROFILE)
peers-a: ## Print host A peer id / multiaddr (PEER=... to connect)
	@bash $(ROOT)/scripts/peers.sh a $(PEER)
peers-b: ## Print host B peer id / multiaddr (PEER=... to connect)
	@bash $(ROOT)/scripts/peers.sh b $(PEER)

compare: ## Compare A and B at a height/tag: RPC_A=... RPC_B=... AT=finalized
	@bash $(ROOT)/scripts/compare-heads.sh $(RPC_A) $(RPC_B) $(AT) $(NODE_A) $(NODE_B)
rebuild-b: ## On host B: wipe and rebuild from L1 only, then compare (TARGET=height REF=rpc)
	@bash $(ROOT)/scripts/rebuild-from-l1.sh $(TARGET) $(REF) $(PROFILE)
deposit: ## Bridge ETH into L2 via OptimismPortal: AMOUNT=0.5 ROLE=deployer L2_RPC=http://...
	@bash $(ROOT)/scripts/deposit.sh $(AMOUNT) $(ROLE) $(L2_RPC)
set-init-bond: ## DGF owner: set initial bond for a game type: TYPE=1 BOND=0
	@bash $(ROOT)/scripts/set-init-bond.sh $(TYPE) $(BOND)

lint: ## Static checks: shellcheck, compose config, JSON/YAML validity
	@shellcheck -x $(ROOT)/scripts/*.sh
	@cd $(ROOT)/node-a && docker compose $(ENV_COMMON) --env-file .env.example config -q
	@cd $(ROOT)/node-b && docker compose $(ENV_COMMON) --env-file .env.example config -q
	@for f in $(ROOT)/manifests/*.json $(ROOT)/registry/*.json; do jq empty $$f || exit 1; done
	@echo "lint passed"
