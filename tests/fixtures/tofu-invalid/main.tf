# Fixture: bricht absichtlich fmt (Einrueckung) und validate (unbekannte
# Variable), damit der Failure-Path des Gates belegt ist.
terraform {
  required_version = ">= 1.9.0"
}

resource "null_resource" "broken" {
      triggers = {
    value = var.does_not_exist
  }
}
