PROVISION_PATH=terraform/main
PACKER_PATH=packer
DEPLOY_PATH=ansible
include .env
export

SERVER_INSTANCE_COUNT := $(shell ls envs/.env.* 2>/dev/null | wc -l)

.PHONY: provision deploy all destroy re build_ami stop start

all: provision deploy

build_ami:
	packer init $(PACKER_PATH)/simulation.pkr.hcl
	@PKR_VAR_AWS_REGION=$(AWS_REGION) \
	packer build $(PACKER_PATH)/simulation.pkr.hcl

provision: terraform
	terraform -chdir=$(PROVISION_PATH) init
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) apply -auto-approve

deploy: ansible
	@chmod 600 terraform/main/.ssh/id_rsa
	ANSIBLE_HOST_KEY_CHECKING=False \
	ANSIBLE_REMOTE_USER=ubuntu \
	AWS_DEFAULT_REGION=$(AWS_REGION) \
	ANSIBLE_PYTHON_INTERPRETER=auto_silent \
	ansible-playbook \
	--flush-cache \
	-i $(DEPLOY_PATH)/inventories \
	--private-key=terraform/main/.ssh/id_rsa \
	--vault-password-file=.vault_pass \
	$(DEPLOY_PATH)/server.yml 

stop: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) apply -auto-approve -var="instance_state=stopped"

start: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) apply -auto-approve -var="instance_state=running"
	@echo "Waiting for EC2 instances to boot up..."
	@sleep 15
	$(MAKE) deploy

destroy: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) destroy -auto-approve

re: destroy all
