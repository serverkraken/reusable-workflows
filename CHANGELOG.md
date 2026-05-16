# Changelog

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
