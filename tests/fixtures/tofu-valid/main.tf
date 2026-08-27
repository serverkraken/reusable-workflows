# Fixture: gueltiger, credential-freier Stack fuer den tofu-validate-Happy-Path.
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
