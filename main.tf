resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "demo" {
           bucket = "morgan-cicd-demo-${random_id.suffix.hex}"
}
