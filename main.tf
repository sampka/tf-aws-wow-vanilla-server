# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Deploy a docker ec2 instance for running a mangos based Vanilla World of Warcraft server
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

###############
# AWS provider
###############
provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.aws_region}"
}

###################################
# Module user-data template script
###################################
data "template_file" "init" {
  template = "${file("${path.module}/templates/instance-entrypoint.tpl")}"

  vars {
    operator_user           = "${var.operator_user}"
    operator_password       = "${var.operator_password}"
    mysql_root_password     = "${var.mysql_root_password}"
    mysql_app_user          = "${var.mysql_app_user}"
    mysql_app_user_password = "${var.mysql_app_user_password}"
  }
}

module "server" {
  # source     = "github.com/ragedunicorn/terraform-aws-rg-docker"
  source     = "../terraform-aws-rg-docker"
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  aws_region = "${var.aws_region}"

  security_groups = [
    "${aws_security_group.ssh.id}",
    "${aws_security_group.outbound.id}",
    "${aws_security_group.wow_vanilla.id}",
  ]

  docker_instance_name = "${var.docker_instance_name}"
  instance_entrypoint  = "${data.template_file.init.rendered}"
  key_name             = "${var.key_name}"
  operator_user        = "${var.operator_user}"
  operator_group       = "${var.operator_group}"
  operator_password    = "${var.operator_password}"
}

##################
# Security groups
##################
resource "aws_security_group" "ssh" {
  name        = "${var.ssh_security_group_name}"
  description = "Default security group with ssh access for any ip-address"

  # ssh
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "outbound" {
  name        = "${var.outbound_security_group_name}"
  description = "Default security group for outbound tcp traffic"

  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "wow_vanilla" {
  name        = "${var.wow_vanilla_security_group_name}"
  description = "Allow incoming traffic to realmd and mangosd"

  # Allow inbound for mangosd
  ingress {
    from_port   = 8085
    to_port     = 8085
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow inbound for realmd
  ingress {
    from_port   = 3724
    to_port     = 3724
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###############
# IAM policies
###############
data "aws_iam_policy_document" "cloudwatch_lambda_policy_document" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "arn:aws:logs:*:*:*",
    ]
  }
}

data "aws_iam_policy_document" "ec2_lambda_policy_document" {
  statement {
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeAvailabilityZones",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
    ]

    resources = [
      "arn:aws:ec2:*:*:instance/*",
    ]
  }
}

resource "aws_iam_role_policy" "cloudwatch_lambda_policy" {
  name   = "rg_tf_wow_vanilla_server_cloudwatch"
  role   = "${aws_iam_role.lambda_execution_role.id}"
  policy = "${data.aws_iam_policy_document.cloudwatch_lambda_policy_document.json}"
}

resource "aws_iam_role_policy" "ec2_lambda_policy" {
  name   = "rg_tf_wow_vanilla_server_ec2"
  role   = "${aws_iam_role.lambda_execution_role.id}"
  policy = "${data.aws_iam_policy_document.ec2_lambda_policy_document.json}"
}

###########
# IAM role
###########
resource "aws_iam_role" "lambda_execution_role" {
  name = "rg-tf-lambda-wow-vanilla-server"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      }
    }
  ]
}
EOF
}

###################
# Cloudwatch rules
###################
resource "aws_cloudwatch_event_rule" "stop_instance" {
  name                = "rg_tf_ec2_stop_instance"
  description         = "Stop instances nightly"
  schedule_expression = "cron(55 23 * * ? *)"
}

resource "aws_cloudwatch_event_rule" "start_instance" {
  name                = "rg_tf_ec2_start_instance"
  description         = "Start instances in the evening"
  schedule_expression = "cron(5 17 * * ? *)"
}

#########
# Lambda
#########
resource "aws_lambda_function" "start_stop_instance" {
  filename         = "lambda/lambda.zip"
  function_name    = "RGTFStartStopWoWVanillaServer"
  role             = "${aws_iam_role.lambda_execution_role.arn}"
  handler          = "lambda_function"
  source_code_hash = "${base64sha256(file("lambda/lambda.zip"))}"
  runtime          = "python3.6"
  timeout          = 60
}

####################
# Cloudwatch target
####################
resource "aws_cloudwatch_event_target" "stop_instance" {
  rule  = "${aws_cloudwatch_event_rule.stop_instance.name}"
  arn   = "${aws_lambda_function.start_stop_instance.arn}"
  input = "{\"action\": \"stop\",\"region\": \"${var.aws_region}\",\"instanceId\": \"${module.server.id}\"}"
}

resource "aws_cloudwatch_event_target" "start_instance" {
  rule  = "${aws_cloudwatch_event_rule.start_instance.name}"
  arn   = "${aws_lambda_function.start_stop_instance.arn}"
  input = "{\"action\": \"start\",\"region\": \"${var.aws_region}\",\"instanceId\": \"${module.server.id}\"}"
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_lambda_start" {
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.start_stop_instance.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = "${aws_cloudwatch_event_rule.start_instance.arn}"
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_lambda_stop" {
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.start_stop_instance.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = "${aws_cloudwatch_event_rule.stop_instance.arn}"
}
