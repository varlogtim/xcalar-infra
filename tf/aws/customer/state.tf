terraform {
  backend "s3" {
    bucket = "xctfstate-us-east-1"
    key    = "tf/aws/customer/terraform.tfstate"
    region = "us-east-1"
  }
}

## Use the following to load remote state
#data "terraform_remote_state" "customer" {
#  backend = "s3"
#  config {
#    bucket = "xctfstate-us-east-1"
#    key    = "tf/aws/customer/terraform.tfstate"
#    region = "us-east-1"
#  }
#}
