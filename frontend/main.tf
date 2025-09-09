# Lookup Route53 zone
data "aws_route53_zone" "main" {
  name         = local.route53.domain_name
  private_zone = false
}

# SSL for root domain
module "ssl_root" {
  source = "./modules/ssl"
  domain_name = local.route53.domain_name
  route53_zone_id = data.aws_route53_zone.main.zone_id
  app_name = local.app_name
}

module "kms_key" {
  source = "./modules/kms"
  app_name = local.app_name
  env_name = local.env_name
}

module "s3_blue" {
  source = "./modules/s3_blue"
  app_name = local.app_name
  env_name = local.env_name
  kms_key_id = module.kms_key.kms_key_id
  color = "blue"
  depends_on = [module.kms_key]
}

module "s3_green" {
  source = "./modules/s3_green"
  app_name = local.app_name
  env_name = local.env_name
  kms_key_id = module.kms_key.kms_key_id
  color = "green"
  depends_on = [module.kms_key]
}

# CloudFront
module "cloudfront_blue" {
  source = "./modules/cloudfront_blue"
  app_name = local.app_name
  env_name = local.env_name
  origin_domain = local.route53.domain_name
  certificate_arn = module.ssl_root.certificate_arn
  route53_ttl = local.route53.ttl
  color = "blue"
  core_name = local.core_name
  depends_on = [module.ssl_root, module.s3_blue]
}

# CloudFront Green
module "cloudfront_green" {
  source = "./modules/cloudfront_green"
  app_name = local.app_name
  env_name = local.env_name
  origin_domain = local.route53.domain_name
  certificate_arn = module.ssl_root.certificate_arn
  route53_ttl = local.route53.ttl
  color = "green"
  core_name = local.core_name
  depends_on = [module.ssl_root, module.s3_green]
}


# outputs are defined in outputs.tf 