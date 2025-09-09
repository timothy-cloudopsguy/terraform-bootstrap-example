locals {
  # Load the existing properties files from the cdk directory (properties.dev.json / properties.prod.json)
  props = jsondecode(file("${path.module}/properties.${var.environment}.json"))

  # Expose useful values
  env_name   = var.environment
  app_name   = length(trimspace(var.app_name)) > 0 ? var.app_name : "${local.props.app_name}${title(var.environment)}"
  core_name  = length(trimspace(var.core_name)) > 0 ? var.core_name : "${local.props.core_name}${title(var.environment)}"
  route53    = local.props.route53
} 