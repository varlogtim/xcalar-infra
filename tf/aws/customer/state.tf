terraform {
  backend "s3" {
    bucket = "xctfstate-us-east-1"
    key    = "tf"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config {
    bucket = "xctfstate-us-east-1"
    key    = "customer/terraform.tfstate"
    region = "us-east-1"
  }
}
