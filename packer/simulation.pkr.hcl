packer {
  required_plugins {
    ansible = {
      version = "~> 1"
      source  = "github.com/hashicorp/ansible"
    }
    amazon = {
      version = ">= 1.2.1"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "AWS_REGION" {
  type = string
}

source "amazon-ebs" "simulation" {
  region  = var.AWS_REGION

  ami_name      = "simulation-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type = "m7i-flex.large"
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.simulation"]

  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/simulation.yml"
    user = "ubuntu"
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_PYTHON_INTERPRETER=auto_silent",
      "ANSIBLE_SSH_PIPELINING=True"
    ]
  }
}
