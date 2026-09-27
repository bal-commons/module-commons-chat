# Makefile for the Ballerina commons/chat module

# Colors for output
GREEN = \033[0;32m
YELLOW = \033[0;33m
RED = \033[0;31m
NC = \033[0m # No Color

# Get current version from Ballerina.toml
CURRENT_VERSION = $(shell grep '^version = ' Ballerina.toml | cut -d'"' -f2)

.PHONY: help build test pack release

help:
	@echo "Available commands:"
	@echo "  build    - Build the Ballerina project"
	@echo "  test     - Run tests"
	@echo "  pack     - Create bala package"
	@echo "  release  - Full release process (build, test, pack, commit, tag)"

build:
	@echo "$(GREEN)Building Ballerina project...$(NC)"
	bal build

test:
	@echo "$(GREEN)Running tests...$(NC)"
	bal test

pack:
	@echo "$(GREEN)Creating bala package...$(NC)"
	bal pack

release:
	@echo "$(GREEN)Checking for uncommitted Ballerina files...$(NC)"
	@if git status --porcelain | grep '\.bal$$'; then \
		echo "$(RED)Error: There are uncommitted .bal files. Please commit or stash them before release.$(NC)"; \
		echo "$(YELLOW)Uncommitted .bal files:$(NC)"; \
		git status --porcelain | grep '\.bal$$'; \
		exit 1; \
	fi
	@echo "$(YELLOW)Current version: $(CURRENT_VERSION)$(NC)"
	@echo "$(YELLOW)Please enter the new version (semver format, e.g., 1.0.0):$(NC)"
	@read NEW_VERSION; \
	if [ -z "$$NEW_VERSION" ]; then \
		echo "$(RED)Error: Version cannot be empty$(NC)"; \
		exit 1; \
	fi; \
	if ! echo "$$NEW_VERSION" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)*(\+[a-zA-Z0-9]+)*$$' > /dev/null; then \
		echo "$(RED)Error: Invalid semver format. Please use format like 1.0.0$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)Updating version to $$NEW_VERSION...$(NC)"; \
	sed -i '' 's/^version = ".*"/version = "'$$NEW_VERSION'"/' Ballerina.toml; \
	echo "$(GREEN)Step 1: Building Ballerina project...$(NC)"; \
	if ! bal build; then \
		echo "$(RED)Build failed. Aborting release.$(NC)"; \
		git checkout -- Ballerina.toml; \
		exit 1; \
	fi; \
	echo "$(GREEN)Step 2: Running tests...$(NC)"; \
	if ! bal test; then \
		echo "$(RED)Tests failed. Aborting release.$(NC)"; \
		git checkout -- Ballerina.toml; \
		exit 1; \
	fi; \
	echo "$(GREEN)Step 3: Creating bala package...$(NC)"; \
	if ! bal pack; then \
		echo "$(RED)Pack failed. Aborting release.$(NC)"; \
		git checkout -- Ballerina.toml; \
		exit 1; \
	fi; \
	echo "$(GREEN)Step 4: Committing Ballerina.toml and Dependencies.toml...$(NC)"; \
	git add Ballerina.toml Dependencies.toml; \
	git commit -m "Release version $$NEW_VERSION"; \
	echo "$(GREEN)Step 5: Creating and pushing tag v$$NEW_VERSION...$(NC)"; \
	if git tag -l | grep -q "^v$$NEW_VERSION$$"; then \
		echo "$(YELLOW)Tag v$$NEW_VERSION already exists.$(NC)"; \
		echo "$(YELLOW)Do you want to delete and recreate it? (y/N):$(NC)"; \
		read RECREATE_TAG; \
		if [ "$$RECREATE_TAG" = "y" ] || [ "$$RECREATE_TAG" = "Y" ]; then \
			echo "$(GREEN)Deleting existing tag v$$NEW_VERSION...$(NC)"; \
			git tag -d "v$$NEW_VERSION"; \
			git push origin --delete "v$$NEW_VERSION" 2>/dev/null || true; \
			echo "$(GREEN)Creating new tag v$$NEW_VERSION...$(NC)"; \
			git tag "v$$NEW_VERSION"; \
		else \
			echo "$(RED)Aborting release due to existing tag.$(NC)"; \
			git reset --hard HEAD~1; \
			exit 1; \
		fi; \
	else \
		git tag "v$$NEW_VERSION"; \
	fi; \
	git push origin main; \
	git push origin "v$$NEW_VERSION"; \
	echo "$(GREEN)Release process completed successfully!$(NC)"; \
	echo "$(YELLOW)To publish to Ballerina Central, run: bal push$(NC)"
