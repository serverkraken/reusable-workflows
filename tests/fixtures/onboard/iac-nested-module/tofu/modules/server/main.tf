# Fixture: Kindmodul. Es ist KEIN Stack — es hat keine eigene
# .terraform.lock.hcl, also koennte `tofu init -lockfile=readonly` hier gar
# nicht durchlaufen. Beide Detektor-Engines muessen es verwerfen.
variable "name" {
  type = string
}

resource "null_resource" "child" {
  triggers = {
    name = var.name
  }
}
