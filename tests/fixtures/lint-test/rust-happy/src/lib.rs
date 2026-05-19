//! Trivial arithmetic for lint-test fixtures.

/// Return the sum of two integers.
pub fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_positive() {
        assert_eq!(add(2, 3), 5);
    }

    #[test]
    fn add_negative() {
        assert_eq!(add(-1, 1), 0);
    }
}
