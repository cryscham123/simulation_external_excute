output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main_vpc.id
}

output "public_subnets" {
  description = "ID of public subnets"
  value       = [aws_subnet.public.id]
}

output "server_sg_id" {
  description = "ID of server security group"
  value       = aws_security_group.server_sg.id
}
