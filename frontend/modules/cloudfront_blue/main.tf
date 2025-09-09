variable "app_name" { type = string }
variable "env_name" { type = string }
variable "origin_domain" { type = string }
variable "certificate_arn" { type = string }
variable "route53_ttl" { type = number }
variable "color" { type = string }
variable "core_name" { type = string }

locals {
  cert_arn = var.certificate_arn
  suffix = lower(random_id.suffix.hex)
}

resource "random_id" "suffix" {
  byte_length = 2
}

resource "aws_s3_bucket" "cf_logs" {
  bucket = "${lower(var.app_name)}-${var.color}-cf-logs-${local.suffix}"
  # acl    = "private"
}

resource "aws_s3_bucket_ownership_controls" "cf_logs_ownership" {
  bucket = aws_s3_bucket.cf_logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "cf_logs_block" {
  bucket = aws_s3_bucket.cf_logs.id
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

data "aws_ssm_parameter" "bucket_website_domain_name" {
  name = "/${var.app_name}/s3/${var.color}/bucket_website_domain_name"
}

# Example of how to use the core_name to get the certificate ARN, we don't use this one in this code.
data "aws_ssm_parameter" "cert_arn_ssm" {
  name  = "/${var.core_name}/ssl/cert_arn"
}

resource "aws_cloudfront_cache_policy" "cache_policy" {
  name        = "${var.app_name}-${var.color}-cache-policy"
  comment     = "Cache policy for ${var.app_name} (${var.env_name}) ${var.color}"
  default_ttl = 0
  max_ttl     = 86400
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
      cookies {
        items = []
      }
    }
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Cache-Control", "Accept-Encoding"]
      }
    }
    query_strings_config {
      query_string_behavior = "none"
      query_strings {
        items = [] 
      }
    }
  }
}


resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront for ${var.app_name} (${var.env_name}) ${var.color}"
  default_root_object = "app/index.html"

  origin {
    domain_name = data.aws_ssm_parameter.bucket_website_domain_name.value
    origin_id   = "app-${var.color}-origin-${var.origin_domain}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "app-${var.color}-origin-${var.origin_domain}"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.cache_policy.id
  }

  aliases = ["${var.color}-app.${var.origin_domain}"]

  viewer_certificate {
    acm_certificate_arn = local.cert_arn
    ssl_support_method  = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket = aws_s3_bucket.cf_logs.bucket_domain_name
    include_cookies = true
    prefix = "cloudfront-logs/"
  }

  custom_error_response {
    error_code = 404
    response_code = 200
    response_page_path = "/app/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code = 403
    response_code = 404
    response_page_path = "/app/404.html"
    error_caching_min_ttl = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  depends_on = []
}

resource "aws_ssm_parameter" "cf_log_bucket" {
  name  = "/${var.app_name}/cloudfront/${var.color}/s3_log_bucket_name"
  type  = "String"
  value = aws_s3_bucket.cf_logs.bucket
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_parameter" "cf_distribution_id" {
  name  = "/${var.app_name}/cloudfront/${var.color}/distribution_id"
  type  = "String"
  value = aws_cloudfront_distribution.this.id
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_parameter" "cf_distribution_domain" {
  name  = "/${var.app_name}/cloudfront/${var.color}/distribution_domain_name"
  type  = "String"
  value = aws_cloudfront_distribution.this.domain_name
  lifecycle {
    prevent_destroy = true
  }
}

output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "distribution_domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "log_bucket" { value = aws_s3_bucket.cf_logs.bucket }

data "aws_route53_zone" "zone" {
  name         = var.origin_domain
  private_zone = false
}

resource "aws_route53_record" "arecord" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "${var.color}-app.${var.origin_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }

  # ttl = var.route53_ttl
} 