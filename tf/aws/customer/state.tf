terraform {
  backend "s3" {
    bucket = "xctfstate-us-east-1"
    key    = "tf"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "customer" {
  backend = "s3"
  config {
    bucket = "xctfstate-us-east-1"
    key    = "customer/terraform.tfstate"
    region = "us-east-1"
  }
}
