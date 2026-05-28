resource "aws_key_pair" "my_labtop" {
  key_name   = "my_labtop"
  public_key = file(".ssh/id_rsa.pub")
}

module "network" {
  source = "../modules/network"

  AWS_REGION           = var.AWS_REGION
}

resource "aws_instance" "server" {
  count         = var.SERVER_INSTANCE_COUNT
  ami           = data.aws_ami.simulation_ami.id
  instance_type = "m7i-flex.large"

  vpc_security_group_ids = [module.network.server_sg_id]
  subnet_id              = module.network.public_subnets[0]

  key_name = aws_key_pair.my_labtop.key_name
  tags = {
    Name = "serverNode"
  }
}

resource "aws_ec2_instance_state" "server_state" {
  count       = var.SERVER_INSTANCE_COUNT
  instance_id = aws_instance.server[count.index].id
  state       = var.instance_state
}

