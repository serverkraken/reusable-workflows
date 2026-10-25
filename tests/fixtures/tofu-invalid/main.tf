# Fixture: bricht absichtlich fmt (Einrueckung) und validate (unbekannte
# Variable), damit der Failure-Path des Gates belegt ist.
#
# Die .terraform.lock.hcl daneben ist Absicht: `null_resource` impliziert
# hashicorp/null, und ohne Lock scheiterte schon `init -lockfile=readonly`.
# Der Job waere dann zwar rot gewesen, aber aus dem falschen Grund — validate
# lief nie. Mit Lock ist init gruen und validate ist das, was bricht.
terraform {
  required_version = ">= 1.9.0"
}

resource "null_resource" "broken" {
      triggers = {
    value = var.does_not_exist
  }
}
