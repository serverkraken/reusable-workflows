# catalog_test_flutter_app

Minimal Flutter project used as a fixture by the catalog's Flutter atom callers
(`caller-flutter-{lint,test,release}-happy.yml`). Not a real app.

`android/release.keystore.b64` is a deliberately **throwaway keystore** committed
as base64 so `flutter build apk --release` can complete in CI without real signing
material. Do not reuse it anywhere real. Trivy fs skips this dir via the existing
`tests/fixtures/**` exclusion. Keystore alias/passwords are documented in the
catalog repo secrets (set by maintainers): alias `catalogtest`, storepass
`catalog-fixture-storepw`, keypass `catalog-fixture-storepw`.
