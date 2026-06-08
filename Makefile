PROVISION_PATH=terraform/main
PACKER_PATH=packer
DEPLOY_PATH=ansible
include .env
export

SERVER_INSTANCE_COUNT := $(shell ls envs/.env.* 2>/dev/null | wc -l)

.PHONY: provision deploy deploy-drive-credentials deploy-upload-support upload-results upload-results-run all destroy re build_ami stop start start-instances pre simulation simulation-status simulation-logs

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

deploy-drive-credentials: ansible
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
	--tags drive_credentials \
	$(DEPLOY_PATH)/server.yml

deploy-upload-support: ansible
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
	--tags drive_credentials,upload_results \
	$(DEPLOY_PATH)/server.yml

stop: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) apply -auto-approve -var="instance_state=stopped"

start-instances: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) apply -auto-approve -var="instance_state=running"
	@echo "Waiting for EC2 instances to boot up..."
	@sleep 15

start: start-instances
	$(MAKE) deploy

pre: build_ami
	$(MAKE) provision
	$(MAKE) stop

simulation:
	$(MAKE) start || { $(MAKE) stop; exit 1;}
	@echo "Simulation service started on EC2 instances."
	@echo "Instances will stop themselves after notebook execution and Google Drive upload finish."
	@echo "Check progress with: make simulation-status"
	@echo "Check logs with: make simulation-logs"

upload-results: start-instances deploy-upload-support
	$(MAKE) upload-results-run
	$(MAKE) stop

upload-results-run: ansible
	@chmod 600 terraform/main/.ssh/id_rsa
	ANSIBLE_HOST_KEY_CHECKING=False \
	ANSIBLE_REMOTE_USER=ubuntu \
	AWS_DEFAULT_REGION=$(AWS_REGION) \
	ANSIBLE_PYTHON_INTERPRETER=auto_silent \
	ansible \
	-i $(DEPLOY_PATH)/inventories \
	--private-key=terraform/main/.ssh/id_rsa \
	-b \
	Name_serverNode \
	-m shell \
	-a 'if systemctl is-active --quiet simulation.service; then echo "simulation.service is still running. Refusing to upload partial results."; exit 1; fi; /home/ubuntu/app/upload_results.sh'

simulation-status: ansible
	@chmod 600 terraform/main/.ssh/id_rsa
	ANSIBLE_HOST_KEY_CHECKING=False \
	ANSIBLE_REMOTE_USER=ubuntu \
	AWS_DEFAULT_REGION=$(AWS_REGION) \
	ANSIBLE_PYTHON_INTERPRETER=auto_silent \
	ansible \
	-i $(DEPLOY_PATH)/inventories \
	--private-key=terraform/main/.ssh/id_rsa \
	Name_serverNode \
	-m shell \
	-a 'printf "service="; systemctl is-active simulation.service || true; printf "status="; cat /var/lib/simulation/status 2>/dev/null || echo unknown; printf "started_at="; cat /var/lib/simulation/started_at 2>/dev/null || echo unknown; printf "finished_at="; cat /var/lib/simulation/finished_at 2>/dev/null || echo unknown'

simulation-logs: ansible
	@chmod 600 terraform/main/.ssh/id_rsa
	ANSIBLE_HOST_KEY_CHECKING=False \
	ANSIBLE_REMOTE_USER=ubuntu \
	AWS_DEFAULT_REGION=$(AWS_REGION) \
	ANSIBLE_PYTHON_INTERPRETER=auto_silent \
	ansible \
	-i $(DEPLOY_PATH)/inventories \
	--private-key=terraform/main/.ssh/id_rsa \
	Name_serverNode \
	-m shell \
	-a 'tail -n 120 /var/log/simulation/simulation.log 2>/dev/null || echo "no simulation log yet"'

destroy: terraform
	@TF_VAR_AWS_REGION=$(AWS_REGION) \
	TF_VAR_SERVER_INSTANCE_COUNT=$(SERVER_INSTANCE_COUNT) \
	terraform -chdir=$(PROVISION_PATH) destroy -auto-approve

re: destroy all
