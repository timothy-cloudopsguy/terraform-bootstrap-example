variable "app_name" { type = string }
variable "env_name" { type = string }
variable "color" { type = string }
variable "kms_key_id" { type = string }

locals {
  suffix = lower(random_id.suffix.hex)
}

resource "random_id" "suffix" {
  byte_length = 2
}

resource "aws_s3_bucket" "site" {
  bucket = "${lower(var.app_name)}-${var.color}-site-${local.suffix}"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "site_versioning" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site_sse" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_id == "" ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_id == "" ? null : var.kms_key_id
    }
  }
}

resource "aws_s3_bucket_public_access_block" "site_block" {
  bucket = aws_s3_bucket.site.id

  block_public_acls   = false
  block_public_policy = false
  ignore_public_acls  = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "site_ownership" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_policy" "site_policy" {
  bucket = aws_s3_bucket.site.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "PublicReadGetObject",
        Effect = "Allow",
        Principal = "*",
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.site.arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_website_configuration" "site_website" {
  bucket = aws_s3_bucket.site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "app/404.html"
  }

  # routing_rule {
  #   condition {
  #     key_prefix_equals = "app/"
  #   }
  #   redirect {
  #     replace_key_with = "app/index.html"
  #   }
  # }
}

resource "aws_ssm_parameter" "s3_bucket_name" {
  name  = "/${var.app_name}/s3/${var.color}/bucket_name"
  type  = "String"
  value = aws_s3_bucket.site.bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_parameter" "bucket_website_domain_name" {
  name  = "/${var.app_name}/s3/${var.color}/bucket_website_domain_name"
  type  = "String"
  value = aws_s3_bucket_website_configuration.site_website.website_endpoint

  lifecycle {
    prevent_destroy = true
  }
}

output "bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.site.arn
}

output "env_name" {
  value = var.env_name
}
