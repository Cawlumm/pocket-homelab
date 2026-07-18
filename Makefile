ALL := postgres nextcloud vaultwarden media books arr obsidian-livesync

# Which stacks to act on: override with `make up STACKS="nextcloud postgres"`,
# else use your saved selection in .enabled-stacks, else all of them.
STACKS ?= $(shell if [ -f .enabled-stacks ]; then tr '\n' ' ' < .enabled-stacks; else echo "$(ALL)"; fi)

.PHONY: help bootstrap up down pull ps logs validate verify stacks

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo "  active stacks: $(STACKS)"

stacks: ## show which stacks are currently selected
	@echo "$(STACKS)"

bootstrap: ## create network + volumes + .env (pick stacks: make bootstrap STACKS="nextcloud vaultwarden")
	@STACKS="$(STACKS)" ./bootstrap.sh

up: ## start selected stacks (DB first) + watchtower
	@echo " $(STACKS) " | grep -q " postgres " && ( cd postgres && docker compose up -d ) || true
	@for s in $(STACKS); do [ "$$s" = postgres ] || ( cd $$s && docker compose up -d ); done
	@docker compose up -d   # top-level watchtower
	@docker ps

down: ## stop selected stacks (keeps volumes/data)
	@docker compose down || true
	@for s in $(STACKS); do ( cd $$s && docker compose down ) || true; done

pull: ## pull newer images for selected stacks
	@for s in $(STACKS); do ( cd $$s && docker compose pull ); done
	@docker compose pull

ps: ## show running containers
	@docker ps

logs: ## tail logs for a service:  make logs S=nextcloud
	@docker logs -f $(S)

validate: ## docker compose config -q on every stack (no changes made)
	@for f in $$(find . -name docker-compose.yml | sort); do echo "== $$f"; docker compose -f $$f config -q && echo ok; done

verify: ## preflight: host ready + stacks configured + compose valid
	./scripts/verify.sh
