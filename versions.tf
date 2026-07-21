terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {
    bucket         = "morgan-tfstate-cicd-demo"
    key            = "cicd-demo/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "morgan-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "eu-west-2"
}