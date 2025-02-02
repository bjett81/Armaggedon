
######################################################################
#  SIEM SUBNET
######################################################################
resource "aws_subnet" "siem_subnet_Tokyo" {
  vpc_id            = aws_vpc.tokyo.id
  cidr_block        = cidrsubnet(aws_vpc.tokyo.cidr_block, 8, 52) # Adjust as needed
  availability_zone = "ap-northeast-1d"
  provider          = aws.tokyo

  tags = {
    Name = "Tokyo RDS Subnet"
  }
}
######################################################################
#  S3 Bucket
######################################################################
resource "random_string" "bucket_name" {
  length  = 8
  special = false
  upper   = false

}

resource "aws_s3_bucket" "SyslogBucket" {
  bucket   = "syslog-bucket-${random_string.bucket_name.result}"
  provider = aws.tokyo

  tags = {
    Name = "Syslog S3 Bucket"
  }

}

resource "aws_s3_bucket" "destination" {
  bucket   = "destination-${random_string.bucket_name.result}"
  provider = aws.osaka

  tags = {
    Name = "destination Bucket"
  }

}



resource "aws_s3_bucket_public_access_block" "SyslogBucket" {
  bucket                  = aws_s3_bucket.SyslogBucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  provider                = aws.tokyo
}
/*
resource "aws_s3_bucket_acl" "SyslogBucket" {
  bucket = aws_s3_bucket.SyslogBucket.id
  acl    = "private"
  provider          = aws.tokyo
}
*/
resource "aws_s3_bucket_server_side_encryption_configuration" "SyslogBucket" {
  bucket   = aws_s3_bucket.SyslogBucket.id
  provider = aws.tokyo

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

######################################################################
#  S3 Bucket Replication
######################################################################
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "replication" {
  name               = "tf-iam-role-replication-12345"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "replication" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]

    resources = [aws_s3_bucket.SyslogBucket.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]

    resources = ["${aws_s3_bucket.SyslogBucket.arn}/*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]

    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }
}

resource "aws_iam_policy" "replication" {
  name   = "tf-iam-role-policy-replication-12345"
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_iam_role_policy_attachment" "replication" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

resource "aws_s3_bucket_replication_configuration" "replication" {
  provider = aws.tokyo

  # Must have bucket versioning enabled first
  depends_on = [aws_s3_bucket_versioning.versioning]

  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.SyslogBucket.id

  rule {
    id = "foobar"

    filter {
      prefix = "foo"
    }

    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD"
    }
  }

}


######################################################################
#  S3 Bucket Versioning
######################################################################
resource "aws_s3_bucket_versioning" "destination" {
  bucket   = aws_s3_bucket.destination.id
  provider = aws.osaka
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket   = aws_s3_bucket.SyslogBucket.id
  provider = aws.tokyo
  versioning_configuration {
    status = "Enabled"
  }

}
######################################################################
#  S3 Bucket Policy
######################################################################
resource "aws_s3_bucket_policy" "SyslogBucketPolicy" {
  bucket = aws_s3_bucket.SyslogBucket.id


  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowPutObjectFromEC2Instances"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::ACCOUNT_ID:role/EC2RoleForLogging"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.SyslogBucket.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption" = "AES256"
          }
        }
      },
      {
        Sid    = "AllowGetObjectForSIEMServer"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::ACCOUNT_ID:role/SIEMServerRole"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.SyslogBucket.arn}/*"
      }
    ]
  })
}

######################################################################
#  SIEM Server
######################################################################
resource "aws_security_group" "siem_sg" {
  name     = "siem-sg"
  vpc_id   = aws_vpc.tokyo.id
  provider = aws.tokyo

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "SIEM Security Group"
  }
}

######################################################################
# Launch Template for SIEM Server
######################################################################
resource "aws_launch_template" "siem_server_lt" {
  name_prefix            = "siem-server-lt-"
  image_id               = "ami-023ff3d4ab11b2525" # Replace with your region-specific AMI
  instance_type          = "t3.medium"
  key_name               = "Siem1" # Ensure this key pair exists
  vpc_security_group_ids = [aws_security_group.siem_sg.id]
  iam_instance_profile {
    name = aws_iam_instance_profile.siem_instance_profile.name
  }
  user_data = filebase64("Grafana.sh")

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }
  provider = aws.tokyo

  tags = {
    Name = "SIEM_Server"
  }
}

######################################################################
# Auto Scaling Group for SIEM Server
######################################################################
resource "aws_autoscaling_group" "siem_asg" {
  launch_template {
    id      = aws_launch_template.siem_server_lt.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.siem_subnet_Tokyo.id]
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  provider            = aws.tokyo


}

######################################################################
# IAM Role and Instance Profile for SIEM Server
######################################################################
resource "aws_iam_role" "siem_instance_role" {
  name = "SIEMInstanceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "siem_instance_policy" {
  name        = "SIEMInstancePolicy"
  description = "Policy for SIEM server instances to interact with S3"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.SyslogBucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "siem_instance_profile" {
  name = "SIEMInstanceProfile"
  role = aws_iam_role.siem_instance_role.name
}

// Create an AMI once the instance has been created and configured store in a S3 bucket and use to restore the server incase regional/avaliability zone outage - No data is stored on the siem directly so no data loss.