//! Lint-failing fixture: bad formatting + clippy warnings.

pub fn  add(a:i64,b:i64)->i64{
    let _unused = 1;
    return a+b;
}
