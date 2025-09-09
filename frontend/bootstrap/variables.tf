variable "environment" {
  description = "Environment"
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "S3 bucket name for Terraform state"
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = "Optional KMS key id for bucket encryption"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Optional tags to apply"
  type        = map(string)
  default     = {}
} 