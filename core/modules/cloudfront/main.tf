variable "app_name" { type = string }
variable "env_name" { type = string }
variable "origin_domain" { type = string }
variable "certificate_arn" { type = string }
variable "route53_ttl" { type = number }

locals {
  cert_arn = var.certificate_arn
  suffix = lower(random_id.suffix.hex)
}

resource "random_id" "suffix" {
  byte_length = 2
}

resource "aws_s3_bucket" "cf_logs" {
  bucket = "${lower(var.app_name)}-cf-logs-${local.suffix}"
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

resource "aws_s3_bucket" "kvs_import" {
  bucket = "${lower(var.app_name)}-cf-kvs-import-${local.suffix}"
  # acl    = "private"
}

resource "aws_s3_bucket_ownership_controls" "kvs_import_ownership" {
  bucket = aws_s3_bucket.kvs_import.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "kvs_import_block" {
  bucket = aws_s3_bucket.kvs_import.id
  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls  = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "kvs_file" {
  bucket       = aws_s3_bucket.kvs_import.id
  key          = "router-${var.env_name}.json"
  content      = file("${path.module}/../../functions/router/router-${var.env_name}.json")
  content_type = "application/json"
}

resource "aws_s3_bucket_policy" "kvs_import_policy" {
  bucket = aws_s3_bucket.kvs_import.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontReadForKVSImport"
        Effect = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action = [ "s3:GetObject", "s3:GetBucketLocation" ]
        Resource = [ aws_s3_bucket.kvs_import.arn, "${aws_s3_bucket.kvs_import.arn}/*" ]
      }
    ]
  })
}

resource "aws_cloudcontrolapi_resource" "cloudfront_kvs" {
  type_name     = "AWS::CloudFront::KeyValueStore"
  desired_state = jsonencode({
    Name        = "${lower(var.app_name)}Routing-${var.env_name}-${local.suffix}",
    Comment     = "KVS for ${var.app_name} ${var.env_name}",
    ImportSource = {
      SourceType = "S3",
      SourceArn  = aws_s3_object.kvs_file.arn
    }
  })

  depends_on = [aws_s3_object.kvs_file, aws_s3_bucket_policy.kvs_import_policy]
}

# KVS ARN - This is used for blue/green deployments, the CICD pipeline will update the KVS.
resource "aws_ssm_parameter" "kvs_arn" {
  name  = "/${var.app_name}/cloudfront/kv_store_arn"
  type  = "String"
  value = jsondecode(aws_cloudcontrolapi_resource.cloudfront_kvs.properties)["Arn"]
}

resource "aws_cloudcontrolapi_resource" "router_function" {
  type_name     = "AWS::CloudFront::Function"
  desired_state = jsonencode({
    Name        = "${lower(var.app_name)}-router-${var.env_name}-${local.suffix}",
    AutoPublish = true, 
    FunctionConfig = {
      Comment                    = "Router function for blue/green deployments",
      Runtime                    = "cloudfront-js-2.0",
      KeyValueStoreAssociations  = [
        { KeyValueStoreARN = jsondecode(aws_cloudcontrolapi_resource.cloudfront_kvs.properties)["Arn"] }
      ]
    },
    FunctionCode = file("${path.module}/../../functions/router/router-${var.env_name}.js")
  })

  depends_on = [aws_cloudcontrolapi_resource.cloudfront_kvs]
}

resource "null_resource" "publish_router_function" {
  depends_on = [ aws_cloudcontrolapi_resource.router_function ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<EOT
NAME="${lower(var.app_name)}-router-${var.env_name}-${local.suffix}"
SSM_NAME="/${var.app_name}/cloudfront/router_function_etag"

# wait for function to exist & get ETag
for i in {1..40}; do
  ETAG=$(aws cloudfront describe-function --name "$NAME" --query 'ETag' --output text 2>/dev/null || true)
  if [ -n "$ETAG" ]; then
    break
  fi
  sleep 6
done

if [ -z "$ETAG" ]; then
  echo "Timed out waiting for CloudFront function $NAME to be available" >&2
  exit 1
fi

# compare with previously published ETag in SSM (if present)
PREV_ETAG=$(aws ssm get-parameter --name "$SSM_NAME" --query 'Parameter.Value' --output text 2>/dev/null || true)
if [ "$PREV_ETAG" = "$ETAG" ]; then
  echo "Function ETag unchanged ($ETAG) - skipping publish"
  exit 0
fi

# Attempt to publish; retry if ETag changed during process
for i in {1..6}; do
  if aws cloudfront publish-function --name "$NAME" --if-match "$ETAG"; then
    echo "Published function $NAME using ETag $ETAG"
    break
  fi
  echo "Publish attempt failed; refreshing ETag and retrying (attempt: $i)"
  ETAG=$(aws cloudfront describe-function --name "$NAME" --query 'ETag' --output text 2>/dev/null || true)
  if [ -z "$ETAG" ]; then
    sleep 3
  fi
  sleep 3
done

# verify publish by reading latest ETag
NEW_ETAG=$(aws cloudfront describe-function --name "$NAME" --query 'ETag' --output text 2>/dev/null || true)
if [ -n "$NEW_ETAG" ]; then
  aws ssm put-parameter --name "$SSM_NAME" --type String --value "$NEW_ETAG" --overwrite >/dev/null 2>&1 || true
  echo "Stored published ETag $NEW_ETAG in SSM $SSM_NAME"
  exit 0
fi

echo "Failed to publish CloudFront function $NAME" >&2
exit 1
EOT
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront for ${var.app_name} (${var.env_name})"
  default_root_object = "index.html"

  origin {
    domain_name = var.origin_domain
    origin_id   = "api-origin-${var.origin_domain}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "api-origin-${var.origin_domain}"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    function_association {
      event_type   = "viewer-request"
      function_arn = jsondecode(aws_cloudcontrolapi_resource.router_function.properties)["FunctionARN"]
    }

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }
  }

  aliases = [var.origin_domain, "www.${var.origin_domain}"]

  viewer_certificate {
    acm_certificate_arn = local.cert_arn
    ssl_support_method  = "sni-only"
  }

  logging_config {
    bucket = aws_s3_bucket.cf_logs.bucket_domain_name
    include_cookies = true
    prefix = "cloudfront-logs/"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  depends_on = []
}

resource "aws_ssm_parameter" "cf_log_bucket" {
  name  = "/${var.app_name}/cloudfront/s3_log_bucket_name"
  type  = "String"
  value = aws_s3_bucket.cf_logs.bucket
}

resource "aws_ssm_parameter" "cf_distribution_id" {
  name  = "/${var.app_name}/cloudfront/distribution_id"
  type  = "String"
  value = aws_cloudfront_distribution.this.id
}

resource "aws_ssm_parameter" "cf_distribution_domain" {
  name  = "/${var.app_name}/cloudfront/distribution_domain_name"
  type  = "String"
  value = aws_cloudfront_distribution.this.domain_name
}

output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "distribution_domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "log_bucket" { value = aws_s3_bucket.cf_logs.bucket } 

data "aws_route53_zone" "zone" {
  name         = var.origin_domain
  private_zone = false
}

resource "aws_route53_record" "root_arecord" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.origin_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }

  # ttl = var.route53_ttl
}

resource "aws_route53_record" "www_arecord" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "www.${var.origin_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }

  # ttl = var.route53_ttl
} 