variable "app_name" { type = string }
variable "env_name" { type = string }

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "kms" {
  description         = "${var.app_name} kms"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17",
    Id = "key-default-1",
    Statement = [
      {
        Sid = "AllowAccountFullAccess",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        Action = "kms:*",
        Resource = "*"
      },
      {
        Sid = "AllowS3Use",
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        Resource = "*"
      },
      {
        Sid = "AllowCICDUse",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/reduktCircleCiMgmt/AssumeRoleSessionCICDRole"
        },
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ],
        Resource = "*"
      }
    ]
  })

  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_parameter" "kms_key_arn" {
  name  = "/${var.app_name}/kms/key_arn"
  type  = "String"
  value = aws_kms_key.kms.arn

  lifecycle {
    prevent_destroy = true
  }
}

output "kms_key_arn" {
  value = aws_kms_key.kms.arn
}

output "kms_key_id" {
  value = aws_kms_key.kms.id
}

output "env_name" {
  value = var.env_name
}
