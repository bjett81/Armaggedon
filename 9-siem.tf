resource "aws_rds_cluster" "aurora_postgres_cluster" {
  cluster_identifier  = "aurora-postgres-cluster"
  engine              = "aurora-postgresql"
  master_username     = "admin1"             # Added master username
  master_password     = "SecurePassword123!" # Added master password
  skip_final_snapshot = true
  provider            = aws.tokyo
}

resource "aws_rds_cluster_instance" "cluster_instances" {
  count              = 2
  cluster_identifier = aws_rds_cluster.aurora_postgres_cluster.id
  instance_class     = "db.r5.large"
  engine             = aws_rds_cluster.aurora_cluster.engine
  provider           = aws.tokyo

  tags = {
    Name        = "tokyo-postgres-instance-${count.index + 1}"
    Environment = "Production"
  }
}

resource "aws_s3_bucket" "syslog_bucket" {
  bucket   = "syslog-bucket-qdik38sr"
  provider = aws.tokyo
}

resource "aws_s3_bucket_public_access_block" "syslog_bucket" {
  bucket   = aws_s3_bucket.syslog_bucket.id
  provider = aws.tokyo

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_acl" "syslog_bucket" {
  bucket   = aws_s3_bucket.syslog_bucket.id
  acl      = "private"
  provider = aws.tokyo
}

resource "aws_s3_bucket_server_side_encryption_configuration" "syslog_bucket" {
  bucket   = aws_s3_bucket.syslog_bucket.id
  provider = aws.tokyo

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "syslog_bucket_policy" {
  provider = aws.tokyo
  bucket   = aws_s3_bucket.syslog_bucket.id
  policy   = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "${aws_s3_bucket.syslog_bucket.arn}/*",
        "${aws_s3_bucket.syslog_bucket.arn}"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_launch_template" "siem_template" {
  name_prefix   = "siem-launch-template-"
  image_id      = "ami-0ab02459752898a60"
  instance_type = "t2.micro"
  provider      = aws.tokyo
}

resource "aws_autoscaling_group" "siem_asg" {
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  provider            = aws.tokyo
  vpc_zone_identifier = aws_subnet.private_subnet_Tokyo[*].id
  launch_template {
    id      = aws_launch_template.siem_template.id
    version = "$Latest"
  }
}