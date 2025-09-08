This directory contains a small Terraform configuration to bootstrap the remote backend resources for your Terraform state: an S3 bucket and a DynamoDB table for state locking.

Usage

1. Pick a unique S3 bucket name (must be globally unique) and a DynamoDB table name.
2. Initialize and apply this bootstrap config locally (it uses local state):

```bash
cd core/tf_bootstrap
terraform init
terraform apply -var 'bucket_name=your-unique-bucket-name' -var 'dynamodb_table_name=terraform-locks' -var 'region=us-east-1'
```

3. After apply completes, create a `backend.hcl` file in `core/terraform` (example below) and re-init your main terraform:

Example `core/terraform/backend.hcl`:

```hcl
bucket = "your-unique-bucket-name"
key    = "core/terraform/terraform.tfstate"
region = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt = true
```

Then in `core/terraform` run:

```bash
terraform init -backend-config=../tf_bootstrap/backend.hcl
```

Notes

- You can optionally pass `kms_key_id` to encrypt the bucket with an existing KMS key.
- Ensure your AWS credentials used for CI have put/get permissions on the S3 bucket and read/write for DynamoDB. 