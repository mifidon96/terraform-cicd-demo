resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
  bucket = "morgan-cicd-demo-${random_id.suffix.hex}"

  #checkov:skip=CKV_AWS_18:Access logging requires a second bucket; out of scope for this demo
  #checkov:skip=CKV_AWS_144:Cross-region replication is unnecessary and costly for a sandbox demo
  #checkov:skip=CKV2_AWS_61:Lifecycle configuration not needed; bucket holds no objects
  #checkov:skip=CKV2_AWS_62:Event notifications require an SNS/SQS/Lambda target not present here
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}