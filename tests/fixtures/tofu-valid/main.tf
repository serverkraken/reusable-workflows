# Fixture: gueltiger, credential-freier Stack fuer den tofu-validate-Happy-Path.
#
# Die .terraform.lock.hcl ist GETRACKT und deckt linux_amd64 UND linux_arm64 ab
# (`tofu providers lock -platform=linux_amd64 -platform=linux_arm64`). Sie muss
# das, weil das Atom mit dem Default `lockfile_readonly: true` laeuft: ohne Lock
# bricht `init -lockfile=readonly` mit "Provider dependency changes detected" ab.
# Ein nur auf macOS erzeugter Lock hilft auf einem Linux-Runner nicht.
variable "greeting" {
  type    = string
  default = "hallo"
}

resource "null_resource" "greeter" {
  triggers = {
    greeting = var.greeting
  }
}

output "greeting" {
  value = null_resource.greeter.triggers.greeting
}
