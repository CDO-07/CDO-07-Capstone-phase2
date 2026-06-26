output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "alb_arn" {
  description = "The ARN of the ALB"
  value       = module.alb.arn
}

output "alb_dns_name" {
  description = "The DNS name of the load balancer"
  value       = module.alb.dns_name
}

output "alb_http_listener_arn" {
  description = "The ARN of the ALB HTTP listener"
  value       = module.alb.listeners["http"].arn
}

output "alb_security_group_id" {
  description = "The ID of the ALB security group"
  value       = module.alb.security_group_id
}
