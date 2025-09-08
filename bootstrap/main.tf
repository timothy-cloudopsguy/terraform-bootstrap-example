provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  props = jsondecode(file("${path.module}/../properties.${var.environment}.json"))

  # Pretty name (OK for DynamoDB, tags, etc.)
  env_title           = title(var.environment)
  generated_app_name  = local.props.app_name != "" ? "${local.props.app_name}${local.env_title}" : "coreDev"

  # S3-safe slug (lowercase + hyphens)
  app_slug            = lower(local.props.app_name != "" ? "${local.props.app_name}${var.environment}" : "core-dev")

  acct                = replace(data.aws_caller_identity.current.account_id, ".", "")

  # Force lowercase bucket name
  generated_bucket_name = var.bucket_name != "" ? lower(var.bucket_name) : "${local.acct}-${local.app_slug}-tfstate"

  # DynamoDB can keep the title-cased bit if you like, but for consistency we'll keep it lower
  generated_table_name  = var.dynamodb_table_name != "" ? lower(var.dynamodb_table_name) : lower("${local.acct}-${local.generated_app_name}-tflocks")
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.generated_bucket_name
  tags   = merge({ Name = local.generated_bucket_name }, var.tags)
}

resource "aws_s3_bucket_versioning" "tfstate_versioning" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate_sse" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_id == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_id == "" ? null : var.kms_key_id
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate_block" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = local.generated_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  stream_enabled = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "LockID"
    type = "S"
  }

  replica {
    region_name = "us-east-2"
  }

  tags = merge({ Name = local.generated_table_name }, var.tags)
}

output "generated_bucket_name" { value = local.generated_bucket_name } 
output "generated_table_name" { value = local.generated_table_name } 