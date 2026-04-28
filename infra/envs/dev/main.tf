terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "raw" {
  bucket = "epd-raw-dev-${random_id.suffix.hex}"

  tags = {
    Project = "epd-pipeline"
    Env     = "dev"
  }
}

resource "aws_s3_bucket_versioning" "raw_versioning" {
  bucket = aws_s3_bucket.raw.id

  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_iam_role" "lambda_role" {
  name = "epd-lambda-role-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_lambda_function" "epd_lambda" {
  function_name = "epd-lambda-dev"

  filename         = "../../../lambda/lambda.zip"
  source_code_hash = filebase64sha256("C:/Users/nagar/Projects/epd-pipeline/lambda/lambda.zip")

  handler = "handler.lambda_handler"
  runtime = "python3.11"

  role = aws_iam_role.lambda_role.arn
}
resource "aws_s3_bucket_notification" "raw_events" {
  bucket      = aws_s3_bucket.raw.id
  eventbridge = true
}
resource "aws_cloudwatch_event_rule" "s3_object_created" {
  name        = "epd-s3-object-created-dev"
  description = "Capture object created events for the EPD raw bucket"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.raw.bucket]
      }
      object = {
        key = [{
          prefix = "raw/epd_"
        }]
      }
    }
  })
}
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.s3_object_created.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.epd_lambda.arn
}
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.epd_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_object_created.arn
}
resource "aws_iam_role" "step_function_role" {
  name = "epd-stepfn-role-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
    }]
  })
}
resource "aws_sfn_state_machine" "epd_pipeline" {
  name     = "epd-pipeline-dev"
  role_arn = aws_iam_role.step_function_role.arn

  definition = jsonencode({
    Comment = "EPD pipeline with validation, processing, metadata writing and result branching"
    StartAt = "ValidateFile"
    States = {
      ValidateFile = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.key"
            StringMatches = "*.csv"
            Next          = "ProcessFile"
          }
        ]
        Default = "InvalidFile"
      }

      ProcessFile = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.processor_lambda.arn
          Payload = {
            "bucket.$" = "$.bucket"
            "key.$"    = "$.key"
          }
        }
        OutputPath = "$.Payload"

        Retry = [
          {
            ErrorEquals = [
              "Lambda.ServiceException",
              "Lambda.AWSLambdaException",
              "Lambda.SdkClientException",
              "Lambda.TooManyRequestsException"
            ]
            IntervalSeconds = 2
            MaxAttempts     = 3
            BackoffRate     = 2
          }
        ]

        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error_info"
            Next        = "FailState"
          }
        ]

        Next = "CheckProcessorResult"
      }

      CheckProcessorResult = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.status"
            StringEquals = "processing_complete"
            Next         = "SuccessState"
          },
          {
            Variable     = "$.status"
            StringEquals = "error"
            Next         = "FailState"
          }
        ]
        Default = "FailState"
      }

      SuccessState = {
        Type   = "Pass"
        Result = "File processed and metadata written"
        End    = true
      }

      FailState = {
        Type  = "Fail"
        Error = "ProcessingFailed"
        Cause = "Processor Lambda returned an error status"
      }

      InvalidFile = {
        Type   = "Pass"
        Result = "Invalid file format"
        End    = true
      }
    }
  })
}
resource "aws_iam_role_policy" "lambda_stepfn_policy" {
  name = "lambda-stepfn-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "states:StartExecution"
      ]
      Effect   = "Allow"
      Resource = aws_sfn_state_machine.epd_pipeline.arn
    }]
  })
}
resource "aws_iam_role" "processor_lambda_role" {
  name = "epd-processor-lambda-role-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "processor_lambda_basic" {
  role       = aws_iam_role.processor_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_lambda_function" "processor_lambda" {
  function_name = "epd-processor-lambda-dev"

  filename         = "../../../lambda/lambda.zip"
  source_code_hash = filebase64sha256("C:/Users/nagar/Projects/epd-pipeline/lambda/processor/processor_lambda.zip")

  handler = "handler.lambda_handler"
  runtime = "python3.11"

  role = aws_iam_role.processor_lambda_role.arn
}
resource "aws_iam_role_policy" "stepfn_invoke_processor_lambda" {
  name = "stepfn-invoke-processor-lambda"
  role = aws_iam_role.step_function_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "lambda:InvokeFunction"
      ]
      Effect   = "Allow"
      Resource = aws_lambda_function.processor_lambda.arn
    }]
  })
}
resource "aws_iam_role" "metadata_writer_lambda_role" {
  name = "epd-metadata-writer-lambda-role-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "metadata_writer_lambda_basic" {
  role       = aws_iam_role.metadata_writer_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "metadata_writer_s3_policy" {
  name = "metadata-writer-s3-policy"
  role = aws_iam_role.metadata_writer_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "s3:PutObject"
      ]
      Effect   = "Allow"
      Resource = "${aws_s3_bucket.raw.arn}/*"
    }]
  })
}
resource "aws_lambda_function" "metadata_writer_lambda" {
  function_name = "epd-metadata-writer-lambda-dev"

  filename         = "C:/Users/nagar/Projects/epd-pipeline/lambda/metadata_writer/metadata_writer_lambda.zip"
  source_code_hash = filebase64sha256("C:/Users/nagar/Projects/epd-pipeline/lambda/metadata_writer/metadata_writer_lambda.zip")

  handler = "handler.lambda_handler"
  runtime = "python3.11"

  role = aws_iam_role.metadata_writer_lambda_role.arn
}
resource "aws_iam_role_policy" "stepfn_invoke_metadata_writer_lambda" {
  name = "stepfn-invoke-metadata-writer-lambda"
  role = aws_iam_role.step_function_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "lambda:InvokeFunction"
      ]
      Effect   = "Allow"
      Resource = aws_lambda_function.metadata_writer_lambda.arn
    }]
  })
}
resource "aws_iam_role_policy" "processor_lambda_s3_write_policy" {
  name = "processor-lambda-s3-write-policy"
  role = aws_iam_role.processor_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "s3:PutObject"
      ]
      Effect   = "Allow"
      Resource = "${aws_s3_bucket.raw.arn}/metadata/*"
    }]
  })
}