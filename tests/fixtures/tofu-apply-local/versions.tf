# Kein backend-Block: lokaler State. Die Verschluesselung kommt zur Laufzeit
# ueber TF_ENCRYPTION aus der Composite, nicht aus dieser Datei — so laeuft
# die Fixture denselben Weg wie ein Adopter, der nur eine Passphrase setzt.
terraform {
  required_version = ">= 1.12.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
