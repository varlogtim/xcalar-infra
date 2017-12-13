#s3://xclogs/AWSLogs/559166403383/S3/

module "customer_s3" {
    source = "../modules/customer_s3"
    name = "xc-msci"
    tags  = {
      Customer    = "MSCI"
      Billing     = "customer"
      Environment = "prod"
   }
}

# resource "aws_s3_bucket" "msci" {
#   bucket = "xc-msci"
#   acl    = "private"
#
#   tags {
#     Customer    = "MSCI"
#     Billing     = "customer"
#     Environment = "prod"
#   }
#   logging {
#     target_bucket = "xclogs"
#     target_prefix = "AWSLogs/${var.account_id}/S3/xc-msci"
#   }
# }
#
# resource "aws_iam_group" "msci" {
#   name = "xc-msci"
# }
#
# resource "aws_iam_user" "msci" {
#   name = "xc-msci"
# }
#
# resource "aws_iam_access_key" "msci" {
#   user    = "${aws_iam_user.msci.name}"
# }
#
# resource "aws_iam_group_membership" "msci" {
#   name = "xc-msci"
#
#   users = [
#     "${aws_iam_user.msci.name}"
#   ]
#
#   group = "${aws_iam_group.msci.name}"
# }
#
# resource "aws_iam_group_policy" "msci_s3_full_access" {
#   name  = "xc-msci-s3-full-access"
#   group = "${aws_iam_group.msci.id}"
#   policy = <<EOF
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Effect": "Allow",
#             "Action": [
#                 "s3:ListBucket"
#             ],
#             "Resource": [
#                 "arn:aws:s3:::${aws_s3_bucket.msci.id}"
#             ]
#         },
#         {
#             "Effect": "Allow",
#             "Action": [
#                 "s3:PutObject",
#                 "s3:GetObject",
#                 "s3:DeleteObject"
#             ],
#             "Resource": [
#                 "arn:aws:s3:::${aws_s3_bucket.msci.id}/*"
#             ]
#         }
#     ]
# }
# EOF
#
# }
