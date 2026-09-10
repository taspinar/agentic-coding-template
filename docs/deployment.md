# Deployment

Document environments and deployment here. Recommended path for hosted applications:

PR → CI → merge → staging → smoke checks → human production gate → production.

For GCP, prefer short-lived identity such as Workload Identity Federation over long-lived service-account keys. Production Cloud SQL writes/migrations and IAM changes require explicit approval.
