# Least-privilege user the Pi uses for restic (GIR) + aws s3 sync (archive).
resource "aws_iam_user" "pi_backup" {
  name = "pi_backup"
  path = "/homelab/"
}

resource "aws_iam_access_key" "pi_backup" {
  user = aws_iam_user.pi_backup.name
}

data "aws_iam_policy_document" "pi_backup" {
  # List both buckets
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.gir.arn, aws_s3_bucket.archive.arn]
  }
  # Object ops on both buckets (restic needs Get/Put/Delete; sync the same;
  # Restore/AbortMPU for Deep Archive thaw + multipart cleanup)
  statement {
    sid = "ObjectOps"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:RestoreObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetObjectVersion",
      "s3:DeleteObjectVersion",
    ]
    resources = [
      "${aws_s3_bucket.gir.arn}/*",
      "${aws_s3_bucket.archive.arn}/*",
    ]
  }
}

resource "aws_iam_user_policy" "pi_backup" {
  name   = "pi_backup-s3"
  user   = aws_iam_user.pi_backup.name
  policy = data.aws_iam_policy_document.pi_backup.json
}
