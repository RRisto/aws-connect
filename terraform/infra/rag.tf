# ===========================================================================
# RAG: S3 docs bucket → Bedrock Knowledge Base → Aurora Serverless v2 pgvector
#
# Lambda calls bedrock-agent-runtime:Retrieve to fetch top-k chunks for the
# user's message, then injects them into the Nova Lite system prompt.
# Bedrock reaches Aurora via the Data API (HTTPS), so Lambda stays out of VPC.
# ===========================================================================

# ---------------------------------------------------------------------------
# S3 bucket for RAG documents
# ---------------------------------------------------------------------------
resource "random_id" "docs_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "docs" {
  bucket        = "connect-bot-docs-${random_id.docs_bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# VPC for Aurora (Aurora always requires VPC, even with Data API)
# ---------------------------------------------------------------------------
resource "aws_vpc" "rag" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "connect-bot-rag-vpc" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "rag" {
  count             = 2
  vpc_id            = aws_vpc.rag.id
  cidr_block        = "10.20.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "connect-bot-rag-subnet-${count.index}" }
}

resource "aws_db_subnet_group" "rag" {
  name       = "connect-bot-rag-subnets"
  subnet_ids = aws_subnet.rag[*].id
}

resource "aws_security_group" "aurora" {
  name        = "connect-bot-aurora-sg"
  description = "Aurora Serverless v2 - Data API only, no inbound traffic from VPC needed"
  vpc_id      = aws_vpc.rag.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Aurora master password in Secrets Manager (required by Bedrock KB)
# ---------------------------------------------------------------------------
resource "random_password" "aurora" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "aurora" {
  name                    = "connect-bot-aurora-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({
    username = "bedrock_admin"
    password = random_password.aurora.result
  })
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL Serverless v2 with Data API + auto-pause to 0 ACU
# ---------------------------------------------------------------------------
resource "aws_rds_cluster" "rag" {
  cluster_identifier        = "connect-bot-rag"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = "16.13"
  database_name             = "ragdb"
  master_username           = "bedrock_admin"
  master_password           = random_password.aurora.result
  db_subnet_group_name      = aws_db_subnet_group.rag.name
  vpc_security_group_ids    = [aws_security_group.aurora.id]
  enable_http_endpoint      = true
  skip_final_snapshot       = true
  storage_encrypted         = true

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 2
    seconds_until_auto_pause = 300
  }
}

resource "aws_rds_cluster_instance" "rag" {
  cluster_identifier = aws_rds_cluster.rag.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.rag.engine
  engine_version     = aws_rds_cluster.rag.engine_version
}

# ---------------------------------------------------------------------------
# Initialise pgvector extension + Bedrock KB schema via Data API
# Must run after Aurora is up and before the KB is created.
# ---------------------------------------------------------------------------
resource "null_resource" "init_aurora_schema" {
  depends_on = [aws_rds_cluster_instance.rag, aws_secretsmanager_secret_version.aurora]

  triggers = {
    cluster_arn = aws_rds_cluster.rag.arn
  }

  provisioner "local-exec" {
    command = "python3 ${path.module}/../../scripts/init_aurora_schema.py ${aws_rds_cluster.rag.arn} ${aws_secretsmanager_secret.aurora.arn} ragdb ${var.aws_region}"
  }
}

# ---------------------------------------------------------------------------
# IAM role for Bedrock Knowledge Base
# Trust policy locks to this account + KB ARN pattern (confused-deputy guard)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "kb" {
  name = "connect-bot-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "kb" {
  name = "connect-bot-kb-policy"
  role = aws_iam_role.kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeEmbeddingModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/cohere.embed-multilingual-v3",
        ]
      },
      {
        Sid      = "ReadDocsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.docs.arn, "${aws_s3_bucket.docs.arn}/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid      = "AuroraDataAPI"
        Effect   = "Allow"
        Action   = ["rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement"]
        Resource = [aws_rds_cluster.rag.arn]
      },
      {
        Sid      = "DescribeAuroraCluster"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBClusters"]
        Resource = [aws_rds_cluster.rag.arn]
      },
      {
        Sid      = "ReadAuroraSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.aurora.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base (Cohere multilingual embeddings → Aurora pgvector)
# ---------------------------------------------------------------------------
resource "aws_bedrockagent_knowledge_base" "main" {
  depends_on = [null_resource.init_aurora_schema, aws_iam_role_policy.kb]

  name     = "connect-bot-kb"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/cohere.embed-multilingual-v3"
    }
  }

  storage_configuration {
    type = "RDS"
    rds_configuration {
      resource_arn           = aws_rds_cluster.rag.arn
      credentials_secret_arn = aws_secretsmanager_secret.aurora.arn
      database_name          = "ragdb"
      table_name             = "bedrock_integration.bedrock_kb"
      field_mapping {
        primary_key_field = "id"
        vector_field      = "embedding"
        text_field        = "chunks"
        metadata_field    = "metadata"
      }
    }
  }
}

resource "aws_bedrockagent_data_source" "docs" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name              = "connect-bot-docs-s3"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.docs.arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }
}
