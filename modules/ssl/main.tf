variable "domain_name" {
  type = string
}

variable "route53_zone_id" {
  type = string
}

variable "app_name" {
  type = string
}

resource "aws_acm_certificate" "this" {
  domain_name               = "app.${var.domain_name}"
  subject_alternative_names = ["blue-app.${var.domain_name}", "green-app.${var.domain_name}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  for_each = { for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => dvo }

  zone_id = var.route53_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
  allow_overwrite = true  # helpful if a prior token/record exists
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Store certificate ARN in SSM so downstream stacks can consume it without module outputs
resource "aws_ssm_parameter" "cert_arn_ssm" {
  name  = "/${var.app_name}/ssl/cert_arn"
  type  = "String"
  value = aws_acm_certificate.this.arn
}

output "certificate_arn" {
  value = aws_acm_certificate.this.arn
}

output "certificate_id" {
  value = aws_acm_certificate.this.id
} 