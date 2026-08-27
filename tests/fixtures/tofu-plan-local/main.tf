# Ohne vorhandenen State ist diese Ressource immer "to add" — der Plan meldet
# damit verlaesslich has_changes=true, und genau das prueft die Assertion.
resource "null_resource" "planned" {
  triggers = {
    fixture = "tofu-plan-local"
  }
}
