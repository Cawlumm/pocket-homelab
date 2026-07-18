# CloudWatch dashboard for the homelab backup infra (S3 storage per tier,
# object counts, estimated monthly charges). S3 daily storage metrics are free
# but lag ~24-48h and are daily-granularity, so the dashboard fills in over a day.
resource "aws_cloudwatch_dashboard" "homelab" {
  dashboard_name = "homelab-backups"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Backup storage by tier (bytes)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 86400
          stat    = "Average"
          metrics = [
            ["AWS/S3", "BucketSizeBytes", "StorageType", "GlacierInstantRetrievalStorage", "BucketName", aws_s3_bucket.gir.bucket, { label = "Tier1 GIR data" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "StandardStorage", "BucketName", aws_s3_bucket.gir.bucket, { label = "Tier1 metadata (STANDARD)" }],
            ["AWS/S3", "BucketSizeBytes", "StorageType", "DeepArchiveStorage", "BucketName", aws_s3_bucket.archive.bucket, { label = "Tier2 media (Deep Archive)" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Object counts"
          region = var.aws_region
          view   = "timeSeries"
          period = 86400
          stat   = "Average"
          metrics = [
            ["AWS/S3", "NumberOfObjects", "StorageType", "AllStorageTypes", "BucketName", aws_s3_bucket.gir.bucket, { label = "Tier1 GIR" }],
            ["AWS/S3", "NumberOfObjects", "StorageType", "AllStorageTypes", "BucketName", aws_s3_bucket.archive.bucket, { label = "Tier2 archive" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Estimated charges (USD) - needs billing alerts enabled"
          region = "us-east-1"
          view   = "timeSeries"
          period = 21600
          stat   = "Maximum"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
          ]
        }
      }
    ]
  })
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.homelab.dashboard_name}"
}
