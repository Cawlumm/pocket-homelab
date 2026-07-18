output "gir_bucket" {
  description = "Tier 1 restic bucket (GLACIER_IR)"
  value       = aws_s3_bucket.gir.bucket
}

output "archive_bucket" {
  description = "Tier 2 media bucket (DEEP_ARCHIVE)"
  value       = aws_s3_bucket.archive.bucket
}

output "pi_backup_access_key_id" {
  description = "Access key id for the pi_backup user"
  value       = aws_iam_access_key.pi_backup.id
}

output "pi_backup_secret_access_key" {
  description = "Secret key for pi_backup (sensitive)"
  value       = aws_iam_access_key.pi_backup.secret
  sensitive   = true
}
