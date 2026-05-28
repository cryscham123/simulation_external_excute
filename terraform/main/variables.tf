variable "AWS_REGION" {
  type        = string
  description = "The region in which AWS resources will be created"
}

variable "SERVER_INSTANCE_COUNT" {
  description = "Number of server instances"
  type        = number
}

variable "instance_state" {
  description = "State of the EC2 instances (running or stopped)"
  type        = string
  default     = "running"
}
