# flutter-app-codegen fixture

Minimal Flutter package that **cannot be analysed without code generation**.

`lib/greeting.dart` declares `part 'greeting.g.dart'`, and that file is not in
the repository — it is produced by `dart run build_runner build`, which the
Flutter atoms run when `use_build_runner` is `true` (their default).

## Why it exists

`use_build_runner` defaults to `true` in all four Flutter atoms, and every
caller in the catalog passed `false`. The **default** — the path adopters get —
was never executed (Audit K-10).

Flipping the default to `false` would have been convenient and wrong: a repo
that needs code generation would then silently build against stale generated
files.

## Do not commit `lib/*.g.dart`

It is in `.gitignore` on purpose. If the generated file were committed, the
fixture would analyse cleanly without ever running the generator, and the test
would go back to proving nothing.
