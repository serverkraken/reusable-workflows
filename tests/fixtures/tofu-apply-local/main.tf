# Ein null_resource ohne externe Abhaengigkeit: der Apply-Pfad laesst sich
# damit offline und ohne Credentials durchspielen. Der Trigger ist konstant,
# ein zweiter Apply meldet daher "No changes" — genau das braucht der Test
# fuer einen bereits angewandten Plan.
resource "null_resource" "applied" {
  triggers = {
    fixture = "tofu-apply-local"
  }
}
