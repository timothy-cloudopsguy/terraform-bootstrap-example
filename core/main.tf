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

# CloudFront
module "cloudfront" {
  source = "./modules/cloudfront"
  app_name = local.app_name
  env_name = local.env_name
  origin_domain = local.route53.domain_name
  certificate_arn = module.ssl_root.certificate_arn
  route53_ttl = local.route53.ttl
  depends_on = [module.ssl_root]
}

# outputs are defined in outputs.tf 