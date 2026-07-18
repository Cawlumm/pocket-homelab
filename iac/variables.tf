variable "aws_region" {
  description = "AWS region for the backup bucket"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile (bootstrap admin creds)"
  type        = string
  default     = "homelab-aws"
}

variable "name_prefix" {
  description = "Prefix for globally-unique resource names"
  type        = string
  default     = "homelab-backup"
}

variable "budget_email" {
  description = "Email for billing budget alerts"
  type        = string
  default     = "you@example.com"
}

variable "budget_limit_usd" {
  description = "Monthly budget alert threshold (USD)"
  type        = string
  default     = "5"
}
