# Ein Stack GANZ OHNE Ressourcen. `tofu plan` meldet darauf verlaesslich
# "No changes", und genau das braucht der Drift-Test in der Self-CI:
#
# Ein Lauf MIT Drift wuerde im Katalog-Repo ein echtes Issue anlegen und offen
# stehen lassen. Der Issue-Pfad gehoert deshalb ins Nightly, wo er hinterher
# aufgeraeumt werden kann — hier wird der Ruhezustand geprueft, also dass
# tofu-drift ohne Abweichung has_changes=false meldet und KEIN Issue anfasst.
terraform {
  required_version = ">= 1.12.0"
}
