# Kein backend-Block: lokaler State. Damit laeuft der Plan im Self-CI ohne
# Backend, ohne Credentials und ohne Netzzugang ausser der Provider-Registry.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
