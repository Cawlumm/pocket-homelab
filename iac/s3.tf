# Unique suffix -> globally-unique bucket names
resource "random_id" "suffix" {
  byte_length = 4
}

########################################
# TIER 1 BUCKET -- restic / GLACIER_IR
########################################
resource "aws_s3_bucket" "gir" {
  bucket = "${var.name_prefix}-gir-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_ownership_controls" "gir" {
  bucket = aws_s3_bucket.gir.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "gir" {
  bucket                  = aws_s3_bucket.gir.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gir" {
  bucket = aws_s3_bucket.gir.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "gir" {
  bucket = aws_s3_bucket.gir.id
  versioning_configuration { status = "Enabled" }
}

# restic writes data packs as GLACIER_IR directly (-o s3.storage-class);
# metadata stays STANDARD. No transition rule needed -- just housekeeping.
resource "aws_s3_bucket_lifecycle_configuration" "gir" {
  bucket     = aws_s3_bucket.gir.id
  depends_on = [aws_s3_bucket_versioning.gir]

  rule {
    id     = "abort-incomplete-mpu"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  rule {
    id     = "expire-noncurrent-30d"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

########################################
# TIER 2 BUCKET -- media cold / DEEP_ARCHIVE
# 30-day delete grace via versioning + lifecycle
########################################
resource "aws_s3_bucket" "archive" {
  bucket = "${var.name_prefix}-archive-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_ownership_controls" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

# Versioning ON so aws s3 sync --delete only writes delete markers
# (old versions retained) -> recoverable for the grace window.
resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket     = aws_s3_bucket.archive.id
  depends_on = [aws_s3_bucket_versioning.archive]

  rule {
    id     = "abort-incomplete-mpu"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
  # 30-day grace: noncurrent (deleted/overwritten) versions purge after 30d
  rule {
    id     = "expire-noncurrent-30d"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
  # clean up the delete markers left behind once versions are gone
  rule {
    id     = "expire-delete-markers"
    status = "Enabled"
    filter {}
    expiration { expired_object_delete_marker = true }
  }
}
