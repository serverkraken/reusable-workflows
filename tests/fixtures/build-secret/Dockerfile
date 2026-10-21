# syntax=docker/dockerfile:1
# Fixture for docker-build.yml's `build_secret_repos`: proves that the BuildKit
# secret `github_token` is a valid installation token scoped to EXACTLY the
# configured repositories — and that an unlisted private repo is denied.
#
# Why not "download something from the catalog repo": the catalog is public,
# an anonymous request would succeed too and prove nothing about the token.
# GET /installation/repositories lists precisely the repos the token may
# access; the negative probe shows the restriction is enforced, not just
# declared. The token is read from the mount only, never echoed, no `set -x`.
FROM alpine:3.20
RUN apk add --no-cache curl jq
ARG EXPECTED_REPOS
ARG DENIED_REPO
RUN --mount=type=secret,id=github_token,required=true \
    set -eu; \
    tok="$(cat /run/secrets/github_token)"; \
    got="$(curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      https://api.github.com/installation/repositories \
      | jq -r '[.repositories[].full_name] | sort | join(",")')"; \
    if [ "$got" != "$EXPECTED_REPOS" ]; then \
      echo "token scope: got '$got', expected '$EXPECTED_REPOS'" >&2; exit 1; \
    fi; \
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" \
      "https://api.github.com/repos/$DENIED_REPO")"; \
    if [ "$code" != "404" ]; then \
      echo "unlisted repo $DENIED_REPO answered $code, expected 404" >&2; exit 1; \
    fi; \
    echo "build secret ok: scoped to $got, $DENIED_REPO denied"
CMD ["echo", "build-secret fixture"]
