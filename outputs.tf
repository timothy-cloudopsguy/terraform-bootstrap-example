output "cloudfront_blue_distribution_id" {
  value = module.cloudfront_blue.distribution_id
}

output "cloudfront_blue_distribution_domain_name" {
  value = module.cloudfront_blue.distribution_domain_name
}

output "cloudfront_green_distribution_id" {
  value = module.cloudfront_green.distribution_id
}

output "cloudfront_green_distribution_domain_name" {
  value = module.cloudfront_green.distribution_domain_name
}

output "s3_blue_bucket_name" {
  value = module.s3_blue.bucket_name
}

output "s3_blue_bucket_arn" {
  value = module.s3_blue.bucket_arn
}

output "s3_green_bucket_name" {
  value = module.s3_green.bucket_name
}

output "s3_green_bucket_arn" {
  value = module.s3_green.bucket_arn
}

output "kms_key_arn" {
  value = module.kms_key.kms_key_arn
}

output "kms_key_id" {
  value = module.kms_key.kms_key_id
}

output "acm_certificate_arn" {
  value = module.ssl_root.certificate_arn
} 