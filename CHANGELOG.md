# Changelog

## [3.3.7](https://github.com/serverkraken/reusable-workflows/compare/v3.3.6...v3.3.7) (2026-05-20)


### Bug Fixes

* **atom:** bump golangci-lint default to v2.12.2 + replace bc with awk in test-go gate ([#62](https://github.com/serverkraken/reusable-workflows/issues/62)) ([236611d](https://github.com/serverkraken/reusable-workflows/commit/236611da202622f7be0a768b2f127f3ab9bb1100))

## [3.3.6](https://github.com/serverkraken/reusable-workflows/compare/v3.3.5...v3.3.6) (2026-05-20)


### Bug Fixes

* **atom:** widen docker-build-multi permissions to match nested docker-build.yml ([#60](https://github.com/serverkraken/reusable-workflows/issues/60)) ([be5bdf4](https://github.com/serverkraken/reusable-workflows/commit/be5bdf4e163e617dac3bf99ede8c6d9dc180f1a5))

## [3.3.5](https://github.com/serverkraken/reusable-workflows/compare/v3.3.4...v3.3.5) (2026-05-19)


### Bug Fixes

* **atom:** exclude .catalog/ from python lint/test walks ([#58](https://github.com/serverkraken/reusable-workflows/issues/58)) ([2de05a6](https://github.com/serverkraken/reusable-workflows/commit/2de05a6127fa9ab138b7895bd6406a7fcc87b9af))

## [3.3.4](https://github.com/serverkraken/reusable-workflows/compare/v3.3.3...v3.3.4) (2026-05-19)


### Bug Fixes

* **atom:** install Poetry via pip, not pipx (self-hosted runner compat) ([#56](https://github.com/serverkraken/reusable-workflows/issues/56)) ([0b7b22d](https://github.com/serverkraken/reusable-workflows/commit/0b7b22d5d3bc871b4c0c336c8b4574f62087b58f))

## [3.3.3](https://github.com/serverkraken/reusable-workflows/compare/v3.3.2...v3.3.3) (2026-05-19)


### Bug Fixes

* **atom:** detect Poetry/uv projects by pyproject.toml content, not lockfile ([#54](https://github.com/serverkraken/reusable-workflows/issues/54)) ([15bda2e](https://github.com/serverkraken/reusable-workflows/commit/15bda2eb4b22795afbfb1650a634e84ed4578ca0))

## [3.3.2](https://github.com/serverkraken/reusable-workflows/compare/v3.3.1...v3.3.2) (2026-05-19)


### Bug Fixes

* **deps:** pin astral-sh/setup-uv to v8.1.0 (no floating v8 tag) ([#52](https://github.com/serverkraken/reusable-workflows/issues/52)) ([44a996f](https://github.com/serverkraken/reusable-workflows/commit/44a996fb72b74a5f0ddd6f04b7d8060799eef2fd))

## [3.3.1](https://github.com/serverkraken/reusable-workflows/compare/v3.3.0...v3.3.1) (2026-05-19)


### Bug Fixes

* **atom:** lint-python/test-python need catalog-scoped App token for cross-repo ([#50](https://github.com/serverkraken/reusable-workflows/issues/50)) ([286912e](https://github.com/serverkraken/reusable-workflows/commit/286912ed70e7d992085f29b528ea6ef6e5ba295e))

## [3.3.0](https://github.com/serverkraken/reusable-workflows/compare/v3.2.0...v3.3.0) (2026-05-19)


### Features

* **onboard:** consume lint/test atoms from ci.yml skeleton + unsupported-language warning ([#48](https://github.com/serverkraken/reusable-workflows/issues/48)) ([c74965c](https://github.com/serverkraken/reusable-workflows/commit/c74965c51933c9afbece830ebbb3ca3074cfdfb2))

## [3.2.0](https://github.com/serverkraken/reusable-workflows/compare/v3.1.0...v3.2.0) (2026-05-19)


### Features

* **atoms:** lint-{go,python,rust,helm} and test-{go,python,rust} ([#47](https://github.com/serverkraken/reusable-workflows/issues/47)) ([fa45c39](https://github.com/serverkraken/reusable-workflows/commit/fa45c391ea0cb8fcb6270eefb717694b71a1a5e9))


### Documentation

* lint + test atoms spec and implementation plan ([#45](https://github.com/serverkraken/reusable-workflows/issues/45)) ([3e207d5](https://github.com/serverkraken/reusable-workflows/commit/3e207d5af1a119a23db29421fd96da77b26cbacf))

## [3.1.0](https://github.com/serverkraken/reusable-workflows/compare/v3.0.0...v3.1.0) (2026-05-19)


### Features

* phase 5 — drift-check (smarter onboarding) ([#43](https://github.com/serverkraken/reusable-workflows/issues/43)) ([d58cf58](https://github.com/serverkraken/reusable-workflows/commit/d58cf5825ca1b1a8fa97a4155a1d3fb8b12383d7))

## [3.0.0](https://github.com/serverkraken/reusable-workflows/compare/v2.3.0...v3.0.0) (2026-05-19)


### ⚠ BREAKING CHANGES

* Reusable workflows (docker-build, docker-build-multi, trivy-fs, trivy-image, semantic-release, release) now declare and require the org-level secret `release_please_app_client_id` instead of `release_please_app_id`. Adopters using `secrets: inherit` need the new org secret `RELEASE_PLEASE_APP_CLIENT_ID` to be present (which is the case for the serverkraken org as of 2026-05-19). Adopters on @v2 keep working — only @v3 callers see the new contract.

### Features

* migrate App-token auth to client-id (release-please-bot) ([#41](https://github.com/serverkraken/reusable-workflows/issues/41)) ([e7b2372](https://github.com/serverkraken/reusable-workflows/commit/e7b23728fdf92681df3ec24092a02553cb65f2d5))

## [2.3.0](https://github.com/serverkraken/reusable-workflows/compare/v2.2.0...v2.3.0) (2026-05-19)


### Features

* phase 4 — onboard.yml consumes profile.json (smarter onboarding) ([#39](https://github.com/serverkraken/reusable-workflows/issues/39)) ([2059918](https://github.com/serverkraken/reusable-workflows/commit/205991829e8a3ba5e576c90aff111c8d8a8ef87a))

## [2.2.0](https://github.com/serverkraken/reusable-workflows/compare/v2.1.0...v2.2.0) (2026-05-19)


### Features

* phase 3 — gomplate renderer + lock file (smarter onboarding) ([#24](https://github.com/serverkraken/reusable-workflows/issues/24)) ([be9b1a2](https://github.com/serverkraken/reusable-workflows/commit/be9b1a2bfccb7afe0ff192384d55268cf5c52fb0))

## [2.1.0](https://github.com/serverkraken/reusable-workflows/compare/v2.0.4...v2.1.0) (2026-05-18)


### Features

* phase 1 — new atoms (docker-build-multi, goreleaser, helm-publish) ([#21](https://github.com/serverkraken/reusable-workflows/issues/21)) ([94762ad](https://github.com/serverkraken/reusable-workflows/commit/94762add26520176090b129856ed53dbc8a4c335))
* phase 2 — structured profile.json detection ([#23](https://github.com/serverkraken/reusable-workflows/issues/23)) ([67010c0](https://github.com/serverkraken/reusable-workflows/commit/67010c0dfec55fd1072ceac988770f7b115f7b6b))

## [2.0.4](https://github.com/serverkraken/reusable-workflows/compare/v2.0.3...v2.0.4) (2026-05-17)


### Bug Fixes

* document job-level permissions required by adopter templates ([#19](https://github.com/serverkraken/reusable-workflows/issues/19)) ([26ac898](https://github.com/serverkraken/reusable-workflows/commit/26ac8980f86a5d78c1f56cdda89eecb076df5e00))

## [2.0.3](https://github.com/serverkraken/reusable-workflows/compare/v2.0.2...v2.0.3) (2026-05-16)


### Bug Fixes

* **trivy-atoms:** grant actions:read so SARIF upload works for adopters ([#15](https://github.com/serverkraken/reusable-workflows/issues/15)) ([c4f991b](https://github.com/serverkraken/reusable-workflows/commit/c4f991bd54bff537275093d723709da72ee5525e))

## [2.0.2](https://github.com/serverkraken/reusable-workflows/compare/v2.0.1...v2.0.2) (2026-05-16)


### Bug Fixes

* **catalog-checkout:** pin to floating v2 for cross-repo callers ([#13](https://github.com/serverkraken/reusable-workflows/issues/13)) ([298a4d1](https://github.com/serverkraken/reusable-workflows/commit/298a4d1b658c0ac4769c320ab60593b7a747408f))

## [2.0.1](https://github.com/serverkraken/reusable-workflows/compare/v2.0.0...v2.0.1) (2026-05-16)


### Bug Fixes

* **catalog-checkout:** resolve ref from github.workflow_ref, not workflow_sha ([#11](https://github.com/serverkraken/reusable-workflows/issues/11)) ([7942e48](https://github.com/serverkraken/reusable-workflows/commit/7942e4886e2935c3d6f423b5e87be5367d5d7d63))

## [2.0.0](https://github.com/serverkraken/reusable-workflows/compare/v1.1.1...v2.0.0) (2026-05-16)


### ⚠ BREAKING CHANGES

* trivy-fs.yml, trivy-image.yml, and docker-build.yml now require `secrets.release_please_app_id` and `secrets.release_please_app_private_key`. Callers must pass `secrets: inherit` or fail with "required secret missing". Adopters pinning @v1 are unaffected; @v2 callers must update their templates.

### Features

* add Level-3 onboarding workflow (two-PR adoption flow) ([#7](https://github.com/serverkraken/reusable-workflows/issues/7)) ([7531b39](https://github.com/serverkraken/reusable-workflows/commit/7531b390166080fbad17e98c0ce4065bf78b6388))
* catalog checkout via App-minted token (v2.0.0) ([#10](https://github.com/serverkraken/reusable-workflows/issues/10)) ([6b92e8e](https://github.com/serverkraken/reusable-workflows/commit/6b92e8ed3fa034e2c9a1634d42653d6566b346ef))


### Bug Fixes

* **onboard:** label dry-run skips and seed manifest with stable tags ([#9](https://github.com/serverkraken/reusable-workflows/issues/9)) ([c64a553](https://github.com/serverkraken/reusable-workflows/commit/c64a55385c53178136b75a47af2dcf6515635434))

## [1.1.1](https://github.com/serverkraken/reusable-workflows/compare/v1.1.0...v1.1.1) (2026-05-16)


### Bug Fixes

* **docker-build:** clean /tmp/digests before download on self-hosted ([b3bbf3f](https://github.com/serverkraken/reusable-workflows/commit/b3bbf3f7104aec79f561fe27d92edd2bbeb22074))
* **docker-build:** include image_name in artifact + cache names ([981423f](https://github.com/serverkraken/reusable-workflows/commit/981423f1d3fd142d513f2f838a09348012553524))
* **docker-build:** unambiguous artifact pattern (arch-first naming) ([2f440c6](https://github.com/serverkraken/reusable-workflows/commit/2f440c64ab76633e7023f090d47a3849ffc9f9fe))
* **tests:** swap with-cve fixture from alpine:3.15 to node:10-alpine ([bb4933c](https://github.com/serverkraken/reusable-workflows/commit/bb4933ca9fc9e4d95d8df2bf171893fd28785669))

## [1.1.0](https://github.com/serverkraken/reusable-workflows/compare/v1.0.1...v1.1.0) (2026-05-16)


### Features

* **trivy-fs:** add ignore_unfixed input (matches trivy-image) ([6cca320](https://github.com/serverkraken/reusable-workflows/commit/6cca320ab2b1afd86707f61891bb22cbefef9cbe))


### Bug Fixes

* **cleanup-images:** implement prerelease_age_days filtering ([0dd4f58](https://github.com/serverkraken/reusable-workflows/commit/0dd4f58d539dd9e2b769d6f108103810c362e9c7))
* **docker-build:** include image_name in concurrency group ([21a5edf](https://github.com/serverkraken/reusable-workflows/commit/21a5edf98c660575cd9b17aaf3fd7b3ad2cec4e0))
* **docker-build:** make platforms input filter the matrix ([5dc62b9](https://github.com/serverkraken/reusable-workflows/commit/5dc62b9edb76381292131913ef2a92856cf1e0d7))
* **docker-build:** truncate prerelease SHA to 7 chars ([4657987](https://github.com/serverkraken/reusable-workflows/commit/465798746557fd3b8eabab19039623a1a39395f7))
* **integration:** refactor failure-path to assert on findings_count ([532dde1](https://github.com/serverkraken/reusable-workflows/commit/532dde1bf716eb76577807f5339643e10f82b16e))


### Documentation

* add contracts.md and operations.md referenced by spec ([9a3e3aa](https://github.com/serverkraken/reusable-workflows/commit/9a3e3aa7fa2aa7b8b3b5df59c5815afcc9a94e8f))
* fix yamllint command in CONTRIBUTING.md to include tests/ ([772bc0e](https://github.com/serverkraken/reusable-workflows/commit/772bc0ebfae05fb98ea4204ea7d31f0b7bebc25a))
* **semantic-release:** document concurrency group prefix choice ([fddc1d8](https://github.com/serverkraken/reusable-workflows/commit/fddc1d89255f2cbe03d740924879b8fc6ce8f848))

## [1.0.1](https://github.com/serverkraken/reusable-workflows/compare/v1.0.0...v1.0.1) (2026-05-16)


### Bug Fixes

* **deps:** bump Trivy CLI from 0.69.3 to 0.70.0 ([80e7af6](https://github.com/serverkraken/reusable-workflows/commit/80e7af66466d9d0048bcc3f946f264f6fe8ac7ff))

## 1.0.0 (2026-05-16)


### Features

* initial reusable workflows catalog ([52e2f9e](https://github.com/serverkraken/reusable-workflows/commit/52e2f9ed63ceae78190ad533fd5c633e41896656))


### Documentation

* add adopter workflow templates ([ae42cd3](https://github.com/serverkraken/reusable-workflows/commit/ae42cd332b37ec01dfda5b58177ce35d9889030c))
* add implementation plan for reusable-workflows catalog v0.1.0 ([e8cc8cd](https://github.com/serverkraken/reusable-workflows/commit/e8cc8cd762f65914f5971fd4fa0dbcee34ae4b66))
* initial design spec for reusable-workflows catalog (horizontal slice MVP) ([4cff2a3](https://github.com/serverkraken/reusable-workflows/commit/4cff2a3313bd1d178a082ca95fb7799ef11e0f04))
* rename catalog self-release to catalog-release.yml (resolve filename collision with orchestrator) ([925a60f](https://github.com/serverkraken/reusable-workflows/commit/925a60f30b45e98afe4b7f4a7332a6031a18caba))
* switch release-please auth from PAT to GitHub App ([3182de0](https://github.com/serverkraken/reusable-workflows/commit/3182de0ee0c74b85f83a184e305d19e06265e6d1))
